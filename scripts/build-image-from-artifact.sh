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
# local-dev defaults (KEY=VALUE lines). They are baked into the image as ENV so
# consumers get them by default while remaining overridable at `docker run -e`.
runtime_env_file="$(service_dir "$service")/runtime.env"
dockerfile_content="$(cat "$dockerfile")"
if [[ -f "$runtime_env_file" ]]; then
  runtime_env_lines="$(python3 - "$runtime_env_file" <<'PY'
import sys

lines = []
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"invalid runtime.env line (expected KEY=VALUE): {line}")
        key, value = line.split("=", 1)
        value = value.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'ENV {key.strip()}="{value}"')
print("\n".join(lines))
PY
)"
  if [[ -n "$runtime_env_lines" ]]; then
    log "applying runtime profile from $(relative_to_root "$runtime_env_file")"
    dockerfile_content+=$'\n'"$runtime_env_lines"
  fi
fi

log "building $tag from $rel_rootfs on $BASE_IMAGE for $PLATFORM"
docker_builder="${DOCKER_BUILDER:-$(docker context show 2>/dev/null || echo default)}"
output_args=()
if [[ "${DOCKER_PUSH:-0}" == "1" ]]; then
  output_args+=(--push)
elif [[ "${DOCKER_LOAD:-1}" == "1" ]]; then
  output_args+=(--load)
fi
printf '%s\n' "$dockerfile_content" | docker buildx build \
  --builder "$docker_builder" \
  --platform "$PLATFORM" \
  -f - \
  --build-arg "ARTIFACT_ROOT=$rel_rootfs" \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  -t "$tag" \
  "${output_args[@]}" \
  "$ROOT_DIR"

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
