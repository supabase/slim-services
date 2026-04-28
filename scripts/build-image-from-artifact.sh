#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-image-from-artifact.sh SERVICE ARTIFACT_ROOTFS [IMAGE_TAG]

Build a slim Docker image from an artifact rootfs using the service Dockerfile.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }

require_cmd docker
require_cmd python3

service="$1"
artifact_rootfs="$2"
tag="${3:-local/$service:slim-artifact}"

load_recipe "$service"
[[ -d "$artifact_rootfs" ]] || fail "artifact rootfs not found: $artifact_rootfs"

rel_rootfs="$(relative_to_root "$artifact_rootfs")"
dockerfile="$(service_dir "$service")/Dockerfile.slim"
[[ -f "$dockerfile" ]] || fail "Dockerfile not found: $dockerfile"

log "building $tag from $rel_rootfs on $BASE_IMAGE"
docker_builder="${DOCKER_BUILDER:-$(docker context show 2>/dev/null || echo default)}"
docker buildx build \
  --builder "$docker_builder" \
  -f "$dockerfile" \
  --build-arg "ARTIFACT_ROOT=$rel_rootfs" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$tag" \
  "$ROOT_DIR"

"$ROOT_DIR/scripts/measure-artifact.sh" "$artifact_rootfs" "" "$tag"

manifest="$(dirname "$artifact_rootfs")/manifest.json"
if [[ -f "$manifest" ]]; then
  image_bytes="$(docker image inspect "$tag" --format '{{.Size}}')"
  python3 - "$manifest" "$tag" "$image_bytes" <<'PY'
import json
import sys

manifest_path, image_tag, image_bytes_raw = sys.argv[1], sys.argv[2], sys.argv[3]
image_bytes = int(image_bytes_raw)

with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

data.setdefault("image", {})
data["image"].update({
    "tag": image_tag,
    "bytes": image_bytes,
    "mib": round(image_bytes / 1024 / 1024, 1),
})

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
fi
