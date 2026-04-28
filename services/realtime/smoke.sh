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
start_postgres realtime_smoke

api_secret='realtime-api-secret-with-at-least-32-characters'
metrics_secret='realtime-metrics-secret-with-at-least-32'
secret_key_base="$(openssl rand -hex 32)"

container="realtime-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::4000 \
  -e DB_HOST="$POSTGRES_CONTAINER" \
  -e DB_PORT=5432 \
  -e DB_USER=postgres \
  -e DB_PASSWORD=postgres \
  -e DB_NAME=realtime_smoke \
  -e DB_ENC_KEY=0123456789abcdef \
  -e API_JWT_SECRET="$api_secret" \
  -e METRICS_JWT_SECRET="$metrics_secret" \
  -e SECRET_KEY_BASE="$secret_key_base" \
  -e APP_NAME=realtime-smoke \
  -e SEED_SELF_HOST=true \
  "$image"
port="$(host_port "$container" 4000)"

log "smoke testing realtime on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/healthcheck" "200" 180 "" "$container"; then
  container_logs "$container"
  fail "realtime /healthcheck did not return 200"
fi
log "realtime smoke passed"
