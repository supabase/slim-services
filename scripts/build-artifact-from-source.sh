#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact-from-source.sh SERVICE [VERSION]

Build SERVICE from its sources/SERVICE git submodule using
services/SERVICE/Dockerfile.artifact or ARTIFACT_DOCKERFILE from the recipe,
then write the common artifact layout:

  artifacts/<service>/<version>/<target-os>-<arch>/rootfs/
  artifacts/<service>/<version>/<target-os>-<arch>/<service>.tar.zst
  artifacts/<service>/<version>/<target-os>-<arch>/manifest.json
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd docker
require_cmd git
require_cmd tar
require_cmd python3

service="$1"
VERSION="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
PLATFORM="${PLATFORM:-$(docker_platform "$TARGET_OS" "$ARCH")}"

load_recipe "$service"

SOURCE_DIR="${SOURCE_DIR:?recipe must define SOURCE_DIR}"
SOURCE_REF="${SOURCE_REF:?recipe must define SOURCE_REF}"
BASE_IMAGE="${BASE_IMAGE:?recipe must define BASE_IMAGE}"
ENTRYPOINT_JSON="${ENTRYPOINT_JSON:?recipe must define ENTRYPOINT_JSON}"
CMD_JSON="${CMD_JSON:-[]}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-${SOURCE_IMAGE:-}}"

source_abs="$ROOT_DIR/$SOURCE_DIR"
artifact_dockerfile="${ARTIFACT_DOCKERFILE:-Dockerfile.artifact}"
dockerfile="$ROOT_DIR/services/$service/$artifact_dockerfile"
artifact_dir="$ROOT_DIR/artifacts/$service/$VERSION/$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"

[[ -d "$source_abs" ]] || fail "source submodule directory not found: $SOURCE_DIR"
[[ -f "$source_abs/.git" || -d "$source_abs/.git" ]] || fail "source directory is not a git checkout: $SOURCE_DIR"
[[ -f "$dockerfile" ]] || fail "artifact Dockerfile not found: $dockerfile"

expected_ref="$(git -C "$source_abs" rev-parse "$SOURCE_REF^{commit}" 2>/dev/null || git -C "$source_abs" rev-parse "$SOURCE_REF")"
actual_ref="$(git -C "$source_abs" rev-parse HEAD)"
if [[ "$actual_ref" != "$expected_ref" ]]; then
  fail "$SOURCE_DIR is at $actual_ref, expected $SOURCE_REF ($expected_ref). Run: git submodule update --init --recursive"
fi

if [[ -n "$(git -C "$source_abs" status --short)" ]]; then
  fail "$SOURCE_DIR has local modifications; source artifact builds require clean submodules"
fi

rm -rf "$rootfs"
mkdir -p "$rootfs" "$artifact_dir"

build_args=(
  --build-arg "SOURCE_DIR=$SOURCE_DIR"
  --build-arg "SERVICE_VERSION=$VERSION"
  --build-arg "BASE_IMAGE=$BASE_IMAGE"
)

if declare -p ARTIFACT_BUILD_ARGS >/dev/null 2>&1; then
  for arg in "${ARTIFACT_BUILD_ARGS[@]}"; do
    build_args+=(--build-arg "$arg")
  done
fi

docker_builder="${DOCKER_BUILDER:-$(docker context show 2>/dev/null || echo default)}"
log "building $service artifact from $SOURCE_DIR@$SOURCE_REF for $PLATFORM using builder $docker_builder"
docker buildx build \
  --builder "$docker_builder" \
  --platform "$PLATFORM" \
  --target artifact \
  --output "type=local,dest=$rootfs" \
  -f "$dockerfile" \
  "${build_args[@]}" \
  "$ROOT_DIR"

"$ROOT_DIR/scripts/prune-runtime-tree.sh" "$rootfs"
archive="$(archive_with_best_available_compressor "$rootfs" "$artifact_dir/$service")"

rootfs_kib="$(du -sk "$rootfs" | awk '{print $1}')"
archive_bytes="$(wc -c < "$archive" | tr -d ' ')"

python3 - "$manifest" <<PY
import json
import os

manifest = {
    "service": "$service",
    "version": "$VERSION",
    "platform": "$PLATFORM",
    "arch": "$ARCH",
    "source_dir": "$SOURCE_DIR",
    "source_ref": "$SOURCE_REF",
    "source_commit": "$actual_ref",
    "upstream_image": "$UPSTREAM_IMAGE",
    "base_image": "$BASE_IMAGE",
    "entrypoint": json.loads("""$ENTRYPOINT_JSON"""),
    "cmd": json.loads("""$CMD_JSON"""),
    "build_mode": "source-submodule",
    "artifact_dockerfile": "$artifact_dockerfile",
    "excluded_file_classes": [
        "sourcemaps",
        "debug-symbols",
        "tests",
        "docs",
        "examples",
        "package-manager-caches",
        "Next tracing manifests"
    ],
    "smoke_command": "scripts/smoke.sh $service --artifact $rootfs",
    "archive": os.path.basename("$archive"),
    "size": {
        "rootfs_bytes": int($rootfs_kib) * 1024,
        "rootfs_mib": round((int($rootfs_kib) * 1024) / 1024 / 1024, 1),
        "archive_bytes": int($archive_bytes),
        "archive_mib": round(int($archive_bytes) / 1024 / 1024, 1)
    }
}

with open("$manifest", "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\\n")
PY

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" "$archive"
log "source artifact ready: $artifact_dir"
