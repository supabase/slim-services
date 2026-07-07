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

Target selection:
  TARGET_OS=linux|darwin  defaults to the host OS
  ARCH=arm64|amd64        defaults to the host architecture
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

service="$1"
shift

load_recipe "$service"

TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
export TARGET_OS ARCH

case "$TARGET_OS" in
  linux|darwin) ;;
  *)
    fail "unsupported artifact target OS for $service: $TARGET_OS"
    ;;
esac

case "${ARTIFACT_BACKEND:-docker-source}" in
  nix)
    exec "$ROOT_DIR/scripts/build-artifact-from-nix.sh" "$service" "$@"
    ;;
  docker-source)
    [[ "$TARGET_OS" == "linux" ]] || fail "docker-source artifacts are only supported for linux targets"
    exec "$ROOT_DIR/scripts/build-artifact-from-source.sh" "$service" "$@"
    ;;
  docker-image)
    # Dockerfile.artifact build rooted at an upstream image (FROM SOURCE_IMAGE)
    # instead of a source submodule; used when pruning a published image is the
    # practical build path (e.g. the Nix-based supabase/postgres image).
    [[ "$TARGET_OS" == "linux" ]] || fail "docker-image artifacts are only supported for linux targets"
    exec "$ROOT_DIR/scripts/build-artifact-from-source.sh" "$service" "$@"
    ;;
  image)
    [[ "$TARGET_OS" == "linux" ]] || fail "image extraction artifacts are only supported for linux targets"
    exec "$ROOT_DIR/scripts/build-artifact-from-image.sh" "$service" "$@"
    ;;
  *)
    fail "unknown ARTIFACT_BACKEND for $service: ${ARTIFACT_BACKEND:-}"
    ;;
esac
