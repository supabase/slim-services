#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
require_cmd curl
image="${IMAGE:?set IMAGE to the image tag to smoke test}"
ensure_image "$image"
ensure_network

container="studio-smoke-$RUN_ID"
run_container "$container" --network "$NETWORK" -p 127.0.0.1::3000 "$image"
port="$(host_port "$container" 3000)"

log "smoke testing studio on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/api/platform/profile" "200" 180 "" "$container"; then
  container_logs "$container"
  fail "studio /api/platform/profile did not return 200"
fi
record_runtime_metrics "$container"
log "studio smoke passed"
