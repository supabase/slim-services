#!/usr/bin/env bash
set -euo pipefail
# Host build for darwin targets (invoked by scripts/build-artifact-from-source.sh
# with SERVICE/VERSION/TARGET_OS/ARCH/SOURCE_DIR/ROOTFS/ROOT_DIR set).
#
# Runs npm ci, the upstream build, the repo's Rolldown overlay, bundle-dist
# preparation, and non-runtime pruning directly on the target host. Native
# modules (fs-xattr) compile for that target during npm ci.
# The pinned Node runtime IS bundled (nix/portable-node) at rootfs node/;
# bin/storage resolves SUPABASE_NODE -> bundled node -> PATH. The archive is
# fully self-contained (no runtime_requires).

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

# Match the upstream production Dockerfile. The same major is passed to
# nix/portable-node below so fs-xattr is built and run with one Node ABI.
node_major="$(upstream_node_major "$SOURCE_DIR")"
node_attribute="nodejs_${node_major}"
log "resolving $node_attribute from pinned nixpkgs"
node_store="$(nixpkgs_build_attr "$node_attribute")"
export PATH="$node_store/bin:$PATH"
log "using $(node --version) / npm $(npm --version)"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/storage-host-build.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

git -C "$SOURCE_DIR" archive HEAD | tar -C "$workdir/" -xf -

# rolldown and upstream's exact packageManager npm go into a temporary prefix
# instead of a global install (the pinned Nix Node can ship an older npm).
NPM_VERSION="${NPM_VERSION:-$(upstream_package_manager_version "$SOURCE_DIR" npm)}"
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
  \( -name '*.d.ts' -o -name '*.d.ts.map' -o -name '*.map' -o -name '*.md' -o -name '*.markdown' -o -name 'README*' -o -name '*.test.js' -o -name '*.test.js.map' \) \
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

log "bundling portable node runtime (nix/portable-node)"
export SLIM_NODE_MAJOR="$node_major"
node_bundle="$(nixpkgs_build_file "$ROOT_DIR/nix/portable-node/default.nix")"
mkdir -p "$ROOTFS/node"
cp -R "$node_bundle"/. "$ROOTFS/node/"
chmod -R u+w "$ROOTFS/node"
if [[ "$TARGET_OS" == "darwin" ]]; then
  # Nix sandbox codesigning can emit signatures that fail OFF the build
  # machine (the libiconv incident); verify and repair with the host's real
  # codesign, mirroring scripts/build-artifact-from-nix.sh.
  find "$ROOTFS/node" -type f | while IFS= read -r macho; do
    file "$macho" 2>/dev/null | grep -q 'Mach-O' || continue
    if ! /usr/bin/codesign --verify "$macho" >/dev/null 2>&1; then
      # Non-fatal: a failed repair leaves a bad signature for the darwin
      # audit to reject, with the reason visible here.
      /usr/bin/codesign --force --sign - "$macho" 2>/dev/null \
        && log "re-signed: ${macho#"$ROOTFS"/}" \
        || log "WARN: re-sign failed: ${macho#"$ROOTFS"/}"
    fi
  done
fi

cat > "$ROOTFS/bin/storage" <<'WRAPPER'
#!/bin/sh
# Thin launcher for the self-contained artifact. Runtime resolution:
# SUPABASE_NODE (explicit override), then the bundled runtime, then PATH.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_BIN="${SUPABASE_NODE:-}"
if [ -z "$NODE_BIN" ] && [ -x "$SCRIPT_DIR/../node/bin/node" ]; then
  NODE_BIN="$SCRIPT_DIR/../node/bin/node"
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
