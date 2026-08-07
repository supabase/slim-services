#!/usr/bin/env bash
set -euo pipefail

# Studio is a target-native Node build: pnpm resolves platform packages while
# producing the framework runtime tree, then the same upstream-selected Node
# major is bundled into the artifact and used by the derived Docker image.

# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nixpkgs-pin.sh
source "$ROOT_DIR/scripts/nixpkgs-pin.sh"

: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${ROOTFS:?ROOTFS is required}"
: "${TARGET_OS:?TARGET_OS is required}"
: "${ARCH:?ARCH is required}"

[[ "$TARGET_OS" == "$(host_os)" ]] || \
  fail "studio host builds cannot cross-compile: target is $TARGET_OS, host is $(host_os)"

require_cmd git
require_cmd tar
require_cmd python3

studio_dir="$SOURCE_DIR/apps/studio"
node_major="$(upstream_node_major "$studio_dir" "$SOURCE_DIR")"
node_attribute="nodejs_${node_major}"
pnpm_version="${PNPM_VERSION:-$(upstream_package_manager_version "$SOURCE_DIR" pnpm)}"
studio_framework="${STUDIO_FRAMEWORK:-$(upstream_docker_arg "$studio_dir" STUDIO_FRAMEWORK)}"

case "$studio_framework" in
  next|tanstack) ;;
  *) fail "unsupported upstream Studio framework: $studio_framework" ;;
esac

turbo_version="$(python3 - "$SOURCE_DIR/package.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    package = json.load(fh)
version = package.get("devDependencies", {}).get("turbo", "")
if not version or version[0] in "^~<>=*":
    raise SystemExit("upstream root package.json must pin an exact turbo version")
print(version)
PY
)"

log "resolving $node_attribute from pinned nixpkgs"
node_store="$(nixpkgs_build_attr "$node_attribute")"
export PATH="$node_store/bin:$PATH"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/studio-host-build.XXXXXX")"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/studio-pruned-build.XXXXXX")"
tool_prefix="$(mktemp -d "${TMPDIR:-/tmp}/studio-host-tools.XXXXXX")"
deploy_dir=""
cleanup_studio_build() {
  rm -rf "$workdir" "$build_dir" "$tool_prefix"
  if [[ -n "$deploy_dir" ]]; then
    rm -rf "$deploy_dir"
  fi
}
trap cleanup_studio_build EXIT

export NPM_CONFIG_PREFIX="$tool_prefix"
npm install -g --no-audit --no-fund "pnpm@${pnpm_version}"
export PATH="$tool_prefix/bin:$PATH"
log "using $(node --version) / pnpm $(pnpm --version) / Studio $studio_framework"

git -C "$SOURCE_DIR" archive HEAD | tar -C "$workdir" -xf -

cd "$workdir"
pnpm dlx "turbo@${turbo_version}" prune studio --docker

cp -R "$workdir/out/json"/. "$build_dir/"
cp "$workdir/out/pnpm-lock.yaml" "$build_dir/pnpm-lock.yaml"
if [[ -d "$workdir/patches" ]]; then
  cp -R "$workdir/patches" "$build_dir/patches"
fi

cd "$build_dir"
pnpm install --frozen-lockfile
cp -R "$workdir/out/full"/. "$build_dir/"

mkdir -p "$ROOTFS/app/apps/studio" "$ROOTFS/bin"
if [[ "$studio_framework" == "next" ]]; then
  pnpm --filter studio exec next build
  cp -R apps/studio/.next/standalone/. "$ROOTFS/app/"
  mkdir -p "$ROOTFS/app/apps/studio/.next"
  cp -R apps/studio/.next/static "$ROOTFS/app/apps/studio/.next/static"
  cp -R apps/studio/public "$ROOTFS/app/apps/studio/public"
else
  NODE_OPTIONS=--max-old-space-size=4096 pnpm --filter studio run build:tanstack
  deploy_dir="$(mktemp -d "${TMPDIR:-/tmp}/studio-deploy.XXXXXX")"
  pnpm --filter studio deploy --prod --legacy --ignore-scripts "$deploy_dir"
  find "$deploy_dir" -mindepth 1 -maxdepth 1 \
    ! -name node_modules ! -name package.json ! -name scripts \
    ! -name instrument.server.mjs ! -name .env \
    -exec rm -rf {} +
  cp -R "$deploy_dir"/. "$ROOTFS/app/apps/studio/"
  cp -R apps/studio/dist "$ROOTFS/app/apps/studio/dist"
  printf "import('./scripts/serve.js')\n" > "$ROOTFS/app/apps/studio/server.js"
  (
    cd "$ROOTFS/app/apps/studio"
    node scripts/smoke-server.mjs
  )
fi

cp "$ROOT_DIR/services/studio/overlay/docker-entrypoint.mjs" \
  "$ROOTFS/app/apps/studio/docker-entrypoint.mjs"

# Packages such as the Sentry profiler can carry every platform prebuild in a
# single npm package. Keep only this artifact's platform and architecture.
node_arch="x64"
[[ "$ARCH" == "arm64" ]] && node_arch="arm64"
find "$ROOTFS/app" -type f -name 'sentry_cpu_profiler-*.node' \
  ! -name "sentry_cpu_profiler-${TARGET_OS}-${node_arch}-*" -print0 | xargs -0r rm -f
find "$ROOTFS/app" -type f -name '*-musl-*.node' -print0 | xargs -0r rm -f
find "$ROOTFS/app" -type d -path '*/build/Release/obj.target' -prune -print0 | xargs -0r rm -rf
find "$ROOTFS/app" -type f \( -name '*.o' -o -name '*.o.d' \) -print0 | xargs -0r rm -f

log "bundling portable node runtime (nix/portable-node)"
export SLIM_NODE_MAJOR="$node_major"
node_bundle="$(nixpkgs_build_file "$ROOT_DIR/nix/portable-node/default.nix")"
mkdir -p "$ROOTFS/node"
cp -R "$node_bundle"/. "$ROOTFS/node/"
chmod -R u+w "$ROOTFS/node"
if [[ "$TARGET_OS" == "darwin" ]]; then
  find "$ROOTFS/node" -type f | while IFS= read -r macho; do
    file "$macho" 2>/dev/null | grep -q 'Mach-O' || continue
    if ! /usr/bin/codesign --verify "$macho" >/dev/null 2>&1; then
      if /usr/bin/codesign --force --sign - "$macho" 2>/dev/null; then
        log "re-signed: ${macho#"$ROOTFS"/}"
      else
        log "WARN: re-sign failed: ${macho#"$ROOTFS"/}"
      fi
    fi
  done
fi

cat > "$ROOTFS/bin/studio" <<'WRAPPER'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_BIN="${SUPABASE_NODE:-}"
if [ -z "$NODE_BIN" ] && [ -x "$SCRIPT_DIR/../node/bin/node" ]; then
  NODE_BIN="$SCRIPT_DIR/../node/bin/node"
fi
if [ -z "$NODE_BIN" ]; then
  NODE_BIN="$(command -v node || true)"
fi
if [ -z "$NODE_BIN" ]; then
  echo "studio: no Node runtime found; set SUPABASE_NODE" >&2
  exit 1
fi
cd "$SCRIPT_DIR/../app"
exec "$NODE_BIN" apps/studio/docker-entrypoint.mjs \
  "$NODE_BIN" apps/studio/server.js "$@"
WRAPPER
chmod 0755 "$ROOTFS/bin/studio"
