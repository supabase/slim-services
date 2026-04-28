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
start_postgres analytics_smoke

secret_key_base="$(openssl rand -hex 32)"
db_encryption_key="$(printf '0123456789abcdef0123456789abcdef' | openssl base64 -A)"

container="analytics-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::4000 \
  -e DB_DATABASE=analytics_smoke \
  -e DB_HOSTNAME="$POSTGRES_CONTAINER" \
  -e DB_PORT=5432 \
  -e DB_USERNAME=postgres \
  -e DB_PASSWORD=postgres \
  -e LOGFLARE_SINGLE_TENANT=true \
  -e LOGFLARE_API_KEY=smoke-api-key \
  -e LOGFLARE_DB_ENCRYPTION_KEY="$db_encryption_key" \
  -e PHX_HTTP_PORT=4000 \
  -e PHX_SECRET_KEY_BASE="$secret_key_base" \
  "$image"
port="$(host_port "$container" 4000)"

log "smoke testing analytics on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/health" "200" 180 "" "$container"; then
  container_logs "$container"
  fail "analytics /health did not return 200"
fi
log "analytics smoke passed"
