#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ci-build-service.sh SERVICE [VERSION]

Build and validate one service for one CI matrix target.

Environment:
  TARGET_OS=linux|darwin  defaults to host OS
  ARCH=arm64|amd64        defaults to host architecture
  IMAGE_TAG=...           optional Linux image tag
  DOCKER_PUSH=1           push Linux image instead of only loading locally
  DOCKER_LOAD=0|1         load Linux image locally, defaults to 1

Steps:
  1. Build artifact rootfs for TARGET_OS/ARCH.
  2. Smoke the artifact.
  3. Create/update the distribution archive.
  4. For Linux only, build the final Docker image and smoke it.
  5. For Linux local images, record gzip-compressed docker-save size.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd python3

service="$1"
version="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
export TARGET_OS ARCH

platform_dir="$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
rootfs="$(artifact_rootfs_path "$service" "$version" "$TARGET_OS" "$ARCH")"
artifact_dir="$(dirname "$rootfs")"
manifest="$artifact_dir/manifest.json"

log "CI target: service=$service version=$version target=$TARGET_OS/$ARCH"

"$ROOT_DIR/scripts/build-artifact.sh" "$service" "$version"

[[ -d "$rootfs" ]] || fail "expected artifact rootfs not found: $rootfs"

log "smoking $service artifact for $platform_dir"
"$ROOT_DIR/scripts/smoke.sh" "$service" --artifact "$rootfs"

archive_prefix="${ARTIFACT_ARCHIVE_PREFIX:-$artifact_dir/$service-$version-$platform_dir}"
log "creating distribution archive for $platform_dir"
"$ROOT_DIR/scripts/archive-artifact.sh" "$rootfs" "$archive_prefix"

if [[ "$TARGET_OS" == "linux" ]]; then
  image_tag="${IMAGE_TAG:-local/$service:slim-$version-linux-$ARCH}"

  log "building Linux Docker image: $image_tag"
  PLATFORM="$(docker_platform "$TARGET_OS" "$ARCH")" \
    "$ROOT_DIR/scripts/build-image-from-artifact.sh" "$service" "$rootfs" "$image_tag"

  if [[ "${DOCKER_PUSH:-0}" != "1" ]]; then
    log "smoking Linux Docker image: $image_tag"
    "$ROOT_DIR/scripts/smoke.sh" "$service" --image "$image_tag"

    if command -v docker >/dev/null 2>&1; then
      log "measuring gzip-compressed Docker archive: $image_tag"
      gzip_bytes="$(
        docker save "$image_tag" | gzip -9 | wc -c | tr -d ' '
      )"
      if [[ -f "$manifest" ]]; then
        python3 - "$manifest" "$gzip_bytes" <<'PY'
import json
import sys

manifest_path, gzip_bytes_raw = sys.argv[1:]
gzip_bytes = int(gzip_bytes_raw)

with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

data.setdefault("image", {})
data["image"]["gzip_bytes"] = gzip_bytes
data["image"]["gzip_mib"] = round(gzip_bytes / 1024 / 1024, 1)

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
      fi
      awk -v bytes="$gzip_bytes" 'BEGIN { printf "image_gzip_mib=%.1f\n", bytes / 1024 / 1024 }'
    fi
  else
    log "skipping local image smoke because DOCKER_PUSH=1"
  fi
elif [[ "$TARGET_OS" == "darwin" ]]; then
  log "Darwin target complete; Docker images are only produced for Linux targets"
else
  fail "unsupported CI target OS: $TARGET_OS"
fi

log "CI build complete: $artifact_dir"
