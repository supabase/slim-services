#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
require_cmd curl
image="${IMAGE:?set IMAGE to the image tag to smoke test}"
ensure_image "$image"
start_postgres pgmeta_smoke

container="pgmeta-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::8080 \
  -e PG_META_PORT=8080 \
  -e PG_META_DB_HOST="$POSTGRES_CONTAINER" \
  -e PG_META_DB_PORT=5432 \
  -e PG_META_DB_NAME=pgmeta_smoke \
  -e PG_META_DB_USER=postgres \
  -e PG_META_DB_PASSWORD=postgres \
  "$image"
port="$(host_port "$container" 8080)"

log "smoke testing pgmeta on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/health" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "pgmeta /health did not return 200"
fi
log "pgmeta smoke passed"
