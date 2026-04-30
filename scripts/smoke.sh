#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/smoke.sh SERVICE --image IMAGE
  scripts/smoke.sh SERVICE --artifact ARTIFACT_ROOTFS

Run the service smoke test.

Image mode smokes an existing Docker image.

Artifact mode uses direct artifact execution when the service supports it and
the artifact platform matches the host. Otherwise, Linux artifacts are smoked by
building a temporary slim Docker image from ARTIFACT_ROOTFS.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 3 ]] || { usage >&2; exit 2; }

service="$1"
mode="$2"
value="$3"

load_recipe "$service"

case "$mode" in
  --image)
    image="$value"
    IMAGE="$image" "$ROOT_DIR/services/$service/smoke.sh"
    ;;
  --artifact)
    require_cmd python3
    artifact_rootfs="$value"
    [[ -d "$artifact_rootfs" ]] || fail "artifact rootfs not found: $artifact_rootfs"
    artifact_dir="$(dirname "$artifact_rootfs")"
    manifest="$artifact_dir/manifest.json"
    if [[ -f "$manifest" ]]; then
      artifact_platform="$(python3 - "$manifest" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("platform") or "")
PY
)"
    else
      artifact_name="$(basename "$artifact_dir")"
      artifact_platform="${artifact_name%%-*}/${artifact_name#*-}"
    fi
    artifact_os="${artifact_platform%%/*}"
    artifact_arch="${artifact_platform#*/}"
    artifact_os="$(normalize_os "$artifact_os")"
    artifact_arch="$(normalize_arch "$artifact_arch")"

    if [[ "$artifact_os" != "linux" && "${SUPPORTS_DIRECT_ARTIFACT_SMOKE:-false}" == "true" ]] && host_matches_target "$artifact_os" "$artifact_arch"; then
      ARTIFACT_ROOTFS="$artifact_rootfs" "$ROOT_DIR/services/$service/smoke.sh"
    elif [[ "$artifact_os" == "linux" ]]; then
      run_id="${RUN_ID:-$(date +%s)-$$}"
      image="local/$service:slim-smoke-$artifact_arch-$run_id"
      smoke_platform="$(docker_platform "$artifact_os" "$artifact_arch")"
      UPDATE_MANIFEST=0 PLATFORM="$smoke_platform" \
        "$ROOT_DIR/scripts/build-image-from-artifact.sh" "$service" "$artifact_rootfs" "$image"
      PLATFORM="$smoke_platform" IMAGE="$image" "$ROOT_DIR/services/$service/smoke.sh"
    else
      fail "$service does not support direct artifact smoke for $artifact_os/$artifact_arch on this host"
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
