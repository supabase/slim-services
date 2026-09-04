#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/floor-check-linux.sh SERVICE ROOTFS

Execution proof at the supported glibc floor: run the service's
FLOOR_CHECK_CMD (from services/SERVICE/recipe.env) inside a container whose
glibc IS the floor (default ubuntu:22.04 = glibc 2.35; override with
SLIM_FLOOR_IMAGE). The command sees the artifact at $ROOTFS (read-only) and
must exercise the main binary far enough to prove the dynamic loader
resolves everything: exec + link + NIF/dlopen load. No network is available.

A recipe without FLOOR_CHECK_CMD is skipped WITH A LOG LINE — silence must
never read as coverage; every service that bundles a runtime must set one.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

service="$1"
rootfs="$2"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"

load_recipe "$service"

if [[ -z "${FLOOR_CHECK_CMD:-}" ]]; then
  log "floor check SKIPPED for $service: no FLOOR_CHECK_CMD in recipe (not covered at the glibc floor)"
  exit 0
fi

require_cmd docker
floor_image="${SLIM_FLOOR_IMAGE:-ubuntu:22.04}"
rootfs_abs="$(cd "$rootfs" && pwd)"

log "floor check: $service in $floor_image"
# Release launchers (e.g. supavisor's mix release script) may call `hostname -f`;
# give the container a self-resolving hostname so that doesn't fail under --network none.
if ! docker run --rm --network none \
  --hostname slim-floor-check \
  --add-host slim-floor-check=127.0.0.1 \
  -v "$rootfs_abs":/rootfs:ro \
  -e ROOTFS=/rootfs \
  -e HOME=/tmp \
  -e RELEASE_TMP=/tmp \
  "$floor_image" /bin/bash -c "set -euo pipefail; $FLOOR_CHECK_CMD"; then
  fail "floor check failed for $service in $floor_image (glibc floor violation or launcher regression)"
fi
log "floor check passed: $service runs at the glibc floor ($floor_image)"
