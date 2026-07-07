#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
require_cmd curl
image="${IMAGE:?set IMAGE to the image tag to smoke test}"
ensure_image "$image"

log "checking auth executable"
docker run --rm --entrypoint /usr/local/bin/auth "$image" version >/dev/null

start_postgres auth_smoke
docker exec "$POSTGRES_CONTAINER" sh -lc \
  "psql -h 127.0.0.1 -U postgres -d auth_smoke -c 'CREATE SCHEMA IF NOT EXISTS auth'" \
  >/dev/null

jwt_secret='auth-jwt-secret-with-at-least-32-characters'
container="auth-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::9999 \
  -e GOTRUE_SITE_URL=http://localhost:9999 \
  -e API_EXTERNAL_URL=http://localhost:9999 \
  -e GOTRUE_API_HOST=0.0.0.0 \
  -e PORT=9999 \
  -e GOTRUE_DB_DRIVER=postgres \
  -e GOTRUE_DB_DATABASE_URL="postgres://postgres:postgres@$POSTGRES_CONTAINER:5432/auth_smoke?sslmode=disable" \
  -e GOTRUE_JWT_SECRET="$jwt_secret" \
  -e GOTRUE_JWT_AUD=authenticated \
  -e GOTRUE_LOG_LEVEL=warn \
  "$image"
port="$(host_port "$container" 9999)"

log "smoke testing auth on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/health" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "auth /health did not return 200"
fi
record_runtime_metrics "$container"
log "auth smoke passed"
