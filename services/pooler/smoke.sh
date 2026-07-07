#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
require_cmd curl
require_cmd openssl
image="${IMAGE:?set IMAGE to the image tag to smoke test}"
ensure_image "$image"
start_postgres pooler_smoke

api_secret='pooler-api-secret-with-at-least-32-characters'
metrics_secret='pooler-metrics-secret-with-at-least-32'
secret_key_base="$(openssl rand -hex 32)"
token="$(make_role_jwt "$api_secret" "service_role")"

container="pooler-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::4000 \
  -e DATABASE_URL="ecto://postgres:postgres@$POSTGRES_CONTAINER:5432/pooler_smoke" \
  -e SECRET_KEY_BASE="$secret_key_base" \
  -e API_JWT_SECRET="$api_secret" \
  -e METRICS_JWT_SECRET="$metrics_secret" \
  "$image"
port="$(host_port "$container" 4000)"

log "smoke testing pooler on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/api/health" "204" 180 "$token" "$container"; then
  container_logs "$container"
  fail "pooler /api/health did not return 204"
fi
record_runtime_metrics "$container"
log "pooler smoke passed"
