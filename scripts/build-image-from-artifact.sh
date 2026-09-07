#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nix.sh
source "$ROOT_DIR/scripts/nix.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-image-from-artifact.sh SERVICE ARTIFACT_ROOTFS [IMAGE_TAG]

Build a reproducible OCI image with the pinned Nix dockerTools builder and
load it into Docker. The image is assembled from the exact audited artifact
rootfs passed as the second argument.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }

require_cmd docker
require_cmd python3
require_cmd nix

service="$1"
artifact_rootfs="$2"
tag="${3:-local/$service:slim-artifact}"

load_recipe "$service"
[[ -d "$artifact_rootfs" ]] || fail "artifact rootfs not found: $artifact_rootfs"

platform="${PLATFORM:-}"
manifest="$(dirname "$artifact_rootfs")/manifest.json"
if [[ -z "$platform" && -f "$manifest" ]]; then
  platform="$(python3 - "$manifest" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream).get("platform") or "")
PY
)"
fi
if [[ -z "$platform" ]]; then
  platform="$(docker_platform "$(target_os)" "$(target_arch)")"
fi
platform_os="${platform%%/*}"
platform_arch="${platform#*/}"
platform="$(docker_platform "$platform_os" "$platform_arch")"
nix_system="$(nix_system_for "$platform_os" "$platform_arch")"

identity_json='{}'
identity_dir=""
if identity_service "$service"; then
  # shellcheck source=scripts/identity-lib.sh
  source "$ROOT_DIR/scripts/identity-lib.sh"
  identity_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-identity-build.XXXXXX")"
  cleanup_identity() { rm -rf "$identity_dir"; }
  trap cleanup_identity EXIT
  if [[ "${SKIP_UPSTREAM_IDENTITY:-}" == "1" ]]; then
    fail "SKIP_UPSTREAM_IDENTITY=1 cannot build $service (SOURCE_IMAGE_DIGEST is required)"
  fi
  write_upstream_identity "$service" "$identity_dir"
  # shellcheck source=/dev/null
  source "$identity_dir/identity.env"
  identity_json="$(python3 - "$identity_dir/identity.env" <<'PY'
import json
import shlex
import sys

values = {}
with open(sys.argv[1], encoding="utf-8") as stream:
    for line in stream:
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = shlex.split(value)[0] if value else ""

print(json.dumps({
    "startUser": values.get("START_USER", ""),
    "uid": int(values.get("DROP_TO_UID", "0")),
    "gid": int(values.get("DROP_TO_GID", "0")),
    "name": values.get("DROP_TO_NAME", "root"),
    "mode": values.get("VOLUME_MODE", "755"),
}))
PY
)"
fi

labels_json="$(python3 - <<'PY'
import json
import os

labels = {}
for key, env_name in (
    ("org.opencontainers.image.source", "OCI_SOURCE"),
    ("org.opencontainers.image.revision", "OCI_REVISION"),
    ("org.opencontainers.image.version", "OCI_VERSION"),
):
    value = os.environ.get(env_name)
    if value:
        labels[key] = value
print(json.dumps(labels, separators=(",", ":")))
PY
)"

release_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-image-release.XXXXXX")"
cleanup_release() {
  rm -rf "$release_dir"
  if [[ -n "$identity_dir" ]]; then
    rm -rf "$identity_dir"
  fi
}
trap cleanup_release EXIT
mkdir -p "$release_dir"

# Flake inputs are pure paths. Copying the already audited rootfs into the
# release input keeps the image derivation pure and preserves the exact bytes
# selected by the artifact build (Nix normalizes only derivation metadata).
cp -a "$artifact_rootfs" "$release_dir/rootfs"
python3 - "$release_dir/release.json" "$manifest" "$service" "$tag" "$identity_json" "$labels_json" <<'PY'
import json
import os
import sys

output, manifest_path, service, image_tag, identity_raw, labels_raw = sys.argv[1:]
metadata = {}
if manifest_path and os.path.isfile(manifest_path):
    with open(manifest_path, encoding="utf-8") as stream:
        metadata = json.load(stream)
metadata.update({
    "service": service,
    "image_tag": image_tag,
    "identity": json.loads(identity_raw),
    "labels": json.loads(labels_raw),
})
with open(output, "w", encoding="utf-8") as stream:
    json.dump(metadata, stream, indent=2)
    stream.write("\n")
PY

log "building $tag with pinned Nix dockerTools from $artifact_rootfs on $platform"
image_archive="$(nix_release build "$release_dir" "packages.${nix_system}.image" --no-link --print-out-paths)"
[[ -f "$image_archive" ]] || fail "Nix image output is not a file: $image_archive"

# dockerTools emits a standard docker load archive. Always load it so local
# smoke tests and the release workflow consume the same image bytes. A caller
# asking for DOCKER_PUSH gets the same loaded image pushed afterward.
docker load --input "$image_archive"
docker image inspect "$tag" >/dev/null 2>&1 || fail "Nix image did not load with requested tag $tag"
if [[ "${DOCKER_PUSH:-0}" == "1" ]]; then
  docker push "$tag"
fi

if [[ "${DOCKER_PUSH:-0}" == "1" && "${DOCKER_LOAD:-1}" != "1" ]]; then
  "$ROOT_DIR/scripts/measure-artifact.sh" "$artifact_rootfs"
else
  "$ROOT_DIR/scripts/measure-artifact.sh" "$artifact_rootfs" "" "$tag"
fi

if [[ "${UPDATE_MANIFEST:-1}" == "1" && -f "$manifest" ]]; then
  image_bytes="$(docker image inspect "$tag" --format '{{.Size}}' 2>/dev/null || true)"
  python3 - "$manifest" "$tag" "$image_bytes" <<'PY'
import json
import sys

manifest_path, image_tag, image_bytes_raw = sys.argv[1:]
image_bytes = int(image_bytes_raw) if image_bytes_raw else None
with open(manifest_path, encoding="utf-8") as stream:
    data = json.load(stream)
data.setdefault("image", {})
data["image"].update({
    "tag": image_tag,
    "builder": "nix-dockerTools",
    "bytes": image_bytes,
    "mib": round(image_bytes / 1024 / 1024, 1) if image_bytes is not None else None,
})
with open(manifest_path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
PY
fi
