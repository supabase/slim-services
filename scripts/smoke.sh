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

Run the service smoke test. Artifact mode first builds a temporary slim image
from ARTIFACT_ROOTFS, then runs the same image smoke test.
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
    ;;
  --artifact)
    run_id="${RUN_ID:-$(date +%s)-$$}"
    image="local/$service:slim-smoke-$run_id"
    "$ROOT_DIR/scripts/build-image-from-artifact.sh" "$service" "$value" "$image"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

IMAGE="$image" "$ROOT_DIR/services/$service/smoke.sh"
