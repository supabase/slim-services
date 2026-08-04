#!/usr/bin/env bash
set -euo pipefail
# Host build for darwin targets (invoked by scripts/build-artifact-from-source.sh
# with SERVICE/VERSION/TARGET_OS/ARCH/SOURCE_DIR/ROOTFS/ROOT_DIR set).
#
# Mirrors services/pgmeta/Dockerfile.artifact on the host: npm clean-install,
# tsc build, npm prune, non-runtime file pruning.
# The pinned Node runtime IS bundled (nix/portable-node) at rootfs node/;
# bin/pgmeta resolves SUPABASE_NODE -> bundled node -> PATH. The archive is
# fully self-contained (no runtime_requires).

# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nixpkgs-pin.sh
source "$ROOT_DIR/scripts/nixpkgs-pin.sh"

# npm resolves platform-specific packages for the machine it runs on; Node
# artifacts must be built on a host matching the target.
[[ "$TARGET_OS" == "$(host_os)" ]] || \
  fail "pgmeta host builds cannot cross-compile: target is $TARGET_OS, host is $(host_os)"

require_cmd tar

# Latest Node LTS, same major as the bundled runtime (nix/portable-node).
log "resolving nodejs_24 from pinned nixpkgs"
node_store="$(nixpkgs_build_attr nodejs_24)"
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
  \( -name '*.d.ts' -o -name '*.d.ts.map' -o -name '*.map' -o -name '*.md' -o -name '*.markdown' -o -name 'README*' \) \
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

log "bundling portable node runtime (nix/portable-node)"
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

cat > "$ROOTFS/bin/pgmeta" <<'WRAPPER'
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
  echo "pgmeta: no Node runtime found; set SUPABASE_NODE" >&2
  exit 1
fi
cd "$SCRIPT_DIR/../app"
exec "$NODE_BIN" dist/server/server.js "$@"
WRAPPER
chmod 0755 "$ROOTFS/bin/pgmeta"
