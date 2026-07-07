#!/usr/bin/env bash
set -euo pipefail
# Host build for darwin targets (invoked by scripts/build-artifact-from-source.sh
# with SERVICE/VERSION/TARGET_OS/ARCH/SOURCE_DIR/ROOTFS/ROOT_DIR set).
#
# Mirrors services/pgmeta/Dockerfile.artifact on the host: npm clean-install,
# tsc build, npm prune, non-runtime file pruning. The Node runtime is NOT
# bundled (HOST_NATIVE_PLAN.md Phase 4, Option A): the artifact ships a thin
# bin/pgmeta wrapper that resolves SUPABASE_NODE -> ../../node/bin/node ->
# PATH, and the manifest records runtime_requires=node>=20.

# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nixpkgs-pin.sh
source "$ROOT_DIR/scripts/nixpkgs-pin.sh"

require_cmd tar

# Same Node major as the Docker builder (node:20).
log "resolving nodejs_20 from pinned nixpkgs"
node_store="$(nixpkgs_build_attr nodejs_20)"
export PATH="$node_store/bin:$PATH"
log "using $(node --version) / npm $(npm --version)"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/pgmeta-host-build.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# npm writes into the tree; build from a clean export, sources/ stays pristine.
git -C "$SOURCE_DIR" archive HEAD | tar -C "$workdir" -xf -

cd "$workdir"
npm clean-install --no-audit --no-fund
npm run build
npm prune --omit=dev
find dist node_modules \
  \( -name '*.d.ts' -o -name '*.d.ts.map' -o -name '*.map' -o -name '*.md' -o -name '*.markdown' -o -name 'LICENSE*' -o -name 'README*' \) \
  -type f -print0 | xargs -0r rm -f
find node_modules \
  \( -path '*/test/*' -o -path '*/tests/*' -o -path '*/__tests__/*' -o -path '*/example/*' -o -path '*/examples/*' -o -path '*/benchmark/*' -o -path '*/benchmarks/*' \) \
  -print0 | xargs -0r rm -rf

mkdir -p "$ROOTFS/app" "$ROOTFS/bin"
cp package.json "$ROOTFS/app/package.json"
cp -R dist "$ROOTFS/app/dist"
cp -R node_modules "$ROOTFS/app/node_modules"

cat > "$ROOTFS/bin/pgmeta" <<'WRAPPER'
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
  echo "pgmeta: no Node runtime found; set SUPABASE_NODE" >&2
  exit 1
fi
cd "$SCRIPT_DIR/../app"
exec "$NODE_BIN" dist/server/server.js "$@"
WRAPPER
chmod 0755 "$ROOTFS/bin/pgmeta"
