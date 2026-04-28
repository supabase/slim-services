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
start_postgres storage_smoke

jwt_secret='storage-jwt-secret-with-at-least-32-characters'
container="storage-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::5000 \
  -e DATABASE_URL="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/storage_smoke" \
  -e AUTH_JWT_SECRET="$jwt_secret" \
  -e PGRST_JWT_SECRET="$jwt_secret" \
  -e FILE_STORAGE_BACKEND_PATH=/tmp/storage \
  "$image"
port="$(host_port "$container" 5000)"

log "smoke testing storage on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/status" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "storage /status did not return 200"
fi
log "storage smoke passed"
