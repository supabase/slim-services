#!/usr/bin/env bash
set -euo pipefail
# Host build for darwin targets (invoked by scripts/build-artifact-from-source.sh
# with SERVICE/VERSION/TARGET_OS/ARCH/SOURCE_DIR/ROOTFS/ROOT_DIR set).
#
# Mirrors services/storage/Dockerfile.artifact.rolldown on the host: npm ci,
# upstream build, rolldown bundle with the repo overlay config, bundle-dist
# preparation, non-runtime pruning. Native modules (fs-xattr) compile for
# darwin during npm ci. The Node runtime is NOT bundled (HOST_NATIVE_PLAN.md
# Phase 4, Option A): the artifact ships a thin bin/storage wrapper that
# resolves SUPABASE_NODE -> ../../node/bin/node -> PATH, and the manifest
# records runtime_requires=node>=20 (Docker runtime uses node 24).

# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nixpkgs-pin.sh
source "$ROOT_DIR/scripts/nixpkgs-pin.sh"

# npm resolves platform-specific packages (fs-xattr builds natively) for the
# machine it runs on; storage artifacts must be built on a matching host.
[[ "$TARGET_OS" == "$(host_os)" ]] || \
  fail "storage host builds cannot cross-compile: target is $TARGET_OS, host is $(host_os)"

require_cmd tar
require_cmd python3

ROLLDOWN_VERSION="${ROLLDOWN_VERSION:-1.0.0-rc.17}"
ROLLDOWN_MINIFY="${ROLLDOWN_MINIFY:-1}"

# Same Node major as the Docker builder (node:24).
log "resolving nodejs_24 from pinned nixpkgs"
node_store="$(nixpkgs_build_attr nodejs_24)"
export PATH="$node_store/bin:$PATH"
log "using $(node --version) / npm $(npm --version)"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/storage-host-build.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

git -C "$SOURCE_DIR" archive HEAD | tar -C "$workdir/" -xf -

# rolldown and a newer npm go into a temporary prefix instead of a global
# install (upstream's engines pin wants npm >= 11.12.1; nixpkgs node 24
# ships an older one).
NPM_VERSION="${NPM_VERSION:-11.12.1}"
export NPM_CONFIG_PREFIX="$workdir/.npm-global"
mkdir -p "$NPM_CONFIG_PREFIX"
npm install -g --no-audit --no-fund "npm@${NPM_VERSION}" "rolldown@${ROLLDOWN_VERSION}"
export PATH="$NPM_CONFIG_PREFIX/bin:$PATH"
log "using $(node --version) / npm $(npm --version) after prefix install"

cd "$workdir"
npm ci --no-audit --no-fund
cp "$ROOT_DIR/services/storage/overlay/rolldown.config.mjs" ./rolldown.config.mjs
cp "$ROOT_DIR/services/storage/overlay/bundle-manifest.mjs" ./bundle-manifest.mjs
mkdir -p ./scripts
cp "$ROOT_DIR/services/storage/overlay/scripts/prepare-bundle-dist.mjs" ./scripts/prepare-bundle-dist.mjs

npm run build
if [[ "$ROLLDOWN_MINIFY" == "1" ]]; then
  rolldown -c ./rolldown.config.mjs --minify
else
  rolldown -c ./rolldown.config.mjs
fi
node ./scripts/prepare-bundle-dist.mjs

find dist-bundle dist-bundle/node_modules \
  \( -name '*.d.ts' -o -name '*.d.ts.map' -o -name '*.map' -o -name '*.md' -o -name '*.markdown' -o -name 'LICENSE*' -o -name 'README*' -o -name '*.test.js' -o -name '*.test.js.map' \) \
  -type f -print0 | xargs -0r rm -f
find dist-bundle/node_modules \
  \( -path '*/test/*' -o -path '*/tests/*' -o -path '*/__tests__/*' -o -path '*/example/*' -o -path '*/examples/*' -o -path '*/benchmark/*' -o -path '*/benchmarks/*' \) \
  -print0 | xargs -0r rm -rf
# node-gyp leaves intermediate objects next to the built .node (fs-xattr's
# build/Release/obj.target/**/*.o); they are not runtime files, and their
# unsigned Mach-O objects fail the darwin signature audit.
find dist-bundle/node_modules -type d -path '*/build/Release/obj.target' -prune -print0 | xargs -0r rm -rf
find dist-bundle/node_modules -type f \( -name '*.o' -o -name '*.o.d' \) -print0 | xargs -0r rm -f

mkdir -p "$ROOTFS/app/dist" "$ROOTFS/bin"
cp dist-bundle/package.json "$ROOTFS/app/package.json"
cp -R dist-bundle/start "$ROOTFS/app/dist/start"
cp -R dist-bundle/static "$ROOTFS/app/dist/static"
cp -R dist-bundle/node_modules "$ROOTFS/app/node_modules"
cp -R migrations "$ROOTFS/app/migrations"

cat > "$ROOTFS/bin/storage" <<'WRAPPER'
#!/bin/sh
# Thin launcher: JS bundle + shared Node runtime (HOST_NATIVE_PLAN.md Phase 4
# Option A). Runtime resolution: SUPABASE_NODE, then the CLI's shared runtime
# next to the artifact, then PATH.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_BIN="${SUPABASE_NODE:-}"
if [ -z "$NODE_BIN" ] && [ -x "$SCRIPT_DIR/../../node/bin/node" ]; then
  NODE_BIN="$SCRIPT_DIR/../../node/bin/node"
fi
if [ -z "$NODE_BIN" ]; then
  NODE_BIN="$(command -v node || true)"
fi
if [ -z "$NODE_BIN" ]; then
  echo "storage: no Node runtime found; set SUPABASE_NODE" >&2
  exit 1
fi
cd "$SCRIPT_DIR/../app"
exec "$NODE_BIN" dist/start/server.js "$@"
WRAPPER
chmod 0755 "$ROOTFS/bin/storage"
