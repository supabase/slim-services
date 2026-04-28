#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact.sh SERVICE [VERSION]

Build SERVICE with the backend selected by services/SERVICE/recipe.env:
- ARTIFACT_BACKEND=nix
- ARTIFACT_BACKEND=docker-source
- ARTIFACT_BACKEND=image
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

service="$1"
shift

load_recipe "$service"

case "${ARTIFACT_BACKEND:-docker-source}" in
  nix)
    exec "$ROOT_DIR/scripts/build-artifact-from-nix.sh" "$service" "$@"
    ;;
  docker-source)
    exec "$ROOT_DIR/scripts/build-artifact-from-source.sh" "$service" "$@"
    ;;
  image)
    exec "$ROOT_DIR/scripts/build-artifact-from-image.sh" "$service" "$@"
    ;;
  *)
    fail "unknown ARTIFACT_BACKEND for $service: ${ARTIFACT_BACKEND:-}"
    ;;
esac
