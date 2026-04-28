#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
image="${IMAGE:?set IMAGE to the image tag to smoke test}"
ensure_image "$image"

log "smoke testing edge-runtime: --help"
docker run --rm "$image" --help >/dev/null
log "edge-runtime smoke passed"
