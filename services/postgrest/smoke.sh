#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
require_cmd curl
image="${IMAGE:?set IMAGE to the image tag to smoke test}"
ensure_image "$image"
start_postgres postgrest_smoke

container="postgrest-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::3000 \
  -e PGRST_DB_URI="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/postgrest_smoke" \
  -e PGRST_DB_ANON_ROLE=postgres \
  -e PGRST_DB_SCHEMAS=public \
  -e PGRST_SERVER_PORT=3000 \
  "$image"
port="$(host_port "$container" 3000)"

log "smoke testing postgrest on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "postgrest root endpoint did not return 200"
fi
record_runtime_metrics "$container"
log "postgrest smoke passed"
