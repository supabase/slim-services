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
manifest="$(dirname "$artifact_rootfs")/manifest.json"
if [[ -z "${PLATFORM:-}" && -f "$manifest" ]]; then
  PLATFORM="$(python3 - "$manifest" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    print(json.load(fh).get("platform") or "")
PY
)"
fi
if [[ -z "${PLATFORM:-}" ]]; then
  PLATFORM="$(docker_platform "$(target_os)" "$(target_arch)")"
fi
platform_os="${PLATFORM%%/*}"
platform_arch="${PLATFORM#*/}"
PLATFORM="$(docker_platform "$platform_os" "$platform_arch")"

# Runtime profile contract: services/<service>/runtime.env holds low-footprint
# local-dev defaults, baked into the image as ENV (overridable at `docker run
# -e`). render-dockerfile.sh is the single source of truth for the final
# Dockerfile; CI push paths must use it too.
if [[ -f "$(service_dir "$service")/runtime.env" ]]; then
  log "applying runtime profile from services/$service/runtime.env"
fi
dockerfile_content="$("$ROOT_DIR/scripts/render-dockerfile.sh" "$service")"

identity_build_args=()
if identity_service "$service"; then
  # shellcheck source=scripts/identity-lib.sh
  source "$ROOT_DIR/scripts/identity-lib.sh"
  identity_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-identity-build.XXXXXX")"
  if [[ "${SKIP_UPSTREAM_IDENTITY:-}" == "1" ]]; then
    fail "SKIP_UPSTREAM_IDENTITY=1 cannot build $service (that would invent uid/gid/mode). Unset it; SOURCE_IMAGE_DIGEST is required"
  fi
  write_upstream_identity "$service" "$identity_dir"
  # shellcheck source=/dev/null
  source "$identity_dir/identity.env"
  identity_build_args=(
    --build-arg "DROP_TO_UID=$DROP_TO_UID"
    --build-arg "DROP_TO_GID=$DROP_TO_GID"
    --build-arg "DROP_TO_NAME=$DROP_TO_NAME"
    --build-arg "VOLUME_MODE=$VOLUME_MODE"
  )
fi

log "building $tag from $rel_rootfs on $BASE_IMAGE for $PLATFORM"
docker_builder="${DOCKER_BUILDER:-$(docker context show 2>/dev/null || echo default)}"
output_args=()
if [[ "${DOCKER_PUSH:-0}" == "1" ]]; then
  output_args+=(--push)
elif [[ "${DOCKER_LOAD:-1}" == "1" ]]; then
  output_args+=(--load)
fi
label_args=()
[[ -n "${OCI_SOURCE:-}" ]] && label_args+=(--label "org.opencontainers.image.source=$OCI_SOURCE")
[[ -n "${OCI_REVISION:-}" ]] && label_args+=(--label "org.opencontainers.image.revision=$OCI_REVISION")
[[ -n "${OCI_VERSION:-}" ]] && label_args+=(--label "org.opencontainers.image.version=$OCI_VERSION")
printf '%s\n' "$dockerfile_content" | docker buildx build \
  --builder "$docker_builder" \
  --platform "$PLATFORM" \
  -f - \
  --build-arg "ARTIFACT_ROOT=$rel_rootfs" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  ${identity_build_args[@]+"${identity_build_args[@]}"} \
  -t "$tag" \
  "${label_args[@]}" \
  "${output_args[@]}" \
  "$ROOT_DIR"

if [[ -n "${identity_dir:-}" ]]; then
  rm -rf "$identity_dir"
fi

if [[ "${DOCKER_PUSH:-0}" == "1" && "${DOCKER_LOAD:-0}" != "1" ]]; then
  "$ROOT_DIR/scripts/measure-artifact.sh" "$artifact_rootfs"
else
  "$ROOT_DIR/scripts/measure-artifact.sh" "$artifact_rootfs" "" "$tag"
fi

if [[ "${UPDATE_MANIFEST:-1}" == "1" && -f "$manifest" ]]; then
  if ! image_bytes="$(docker image inspect "$tag" --format '{{.Size}}' 2>/dev/null)"; then
    image_bytes=""
  fi
  python3 - "$manifest" "$tag" "$image_bytes" <<'PY'
import json
import sys

manifest_path, image_tag, image_bytes_raw = sys.argv[1], sys.argv[2], sys.argv[3]
image_bytes = int(image_bytes_raw) if image_bytes_raw else None

with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

data.setdefault("image", {})
data["image"].update({
    "tag": image_tag,
    "bytes": image_bytes,
    "mib": round(image_bytes / 1024 / 1024, 1) if image_bytes is not None else None,
})

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
fi
