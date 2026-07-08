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

# npm resolves platform-specific packages for the machine it runs on; Node
# artifacts must be built on a host matching the target.
[[ "$TARGET_OS" == "$(host_os)" ]] || \
  fail "pgmeta host builds cannot cross-compile: target is $TARGET_OS, host is $(host_os)"

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
# Sentry's cpu profiler ships prebuilt .node binaries for every
# platform/arch/libc in one package. Foreign ones can never load on this
# target and fail the portable audit: musl variants reference
# libc.musl-*.so.1, and the darwin-x64 prebuilds carry code signatures
# that do not verify. Keep only the current platform/arch (plus the musl
# prune, since the keep pattern cannot separate glibc from musl).
node_arch="x64"
[[ "$ARCH" == "arm64" ]] && node_arch="arm64"
find node_modules -type f -name 'sentry_cpu_profiler-*.node' \
  ! -name "sentry_cpu_profiler-${TARGET_OS}-${node_arch}-*" -print0 | xargs -0r rm -f
find node_modules -type f -name '*-musl-*.node' -print0 | xargs -0r rm -f
# node-gyp intermediates (build/Release/obj.target, *.o) are not runtime
# files, and their unsigned Mach-O objects fail the darwin signature audit.
find node_modules -type d -path '*/build/Release/obj.target' -prune -print0 | xargs -0r rm -rf
find node_modules -type f \( -name '*.o' -o -name '*.o.d' \) -print0 | xargs -0r rm -f

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
