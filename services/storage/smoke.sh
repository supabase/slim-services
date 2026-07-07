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
  -e STORAGE_BACKEND=file \
  -e FILE_STORAGE_BACKEND_PATH=/tmp/storage \
  "$image"
port="$(host_port "$container" 5000)"

log "smoke testing storage on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/status" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "storage /status did not return 200"
fi

log "smoke testing storage object round-trip"
# The generic smoke postgres has no supabase grants; give service_role access
# to the storage schema created by the boot migrations.
docker exec "$POSTGRES_CONTAINER" sh -lc "psql -h 127.0.0.1 -U postgres -d storage_smoke <<'SQL'
GRANT USAGE ON SCHEMA storage TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA storage TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA storage TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA storage TO service_role;
SQL" >/dev/null
service_jwt="$(make_role_jwt "$jwt_secret" service_role)"
curl -fsS -X POST \
  -H "Authorization: Bearer $service_jwt" \
  -H 'Content-Type: application/json' \
  -d '{"name":"smoke-bucket"}' \
  "http://127.0.0.1:$port/bucket" >/dev/null \
  || { container_logs "$container"; fail "storage bucket creation failed"; }
curl -fsS -X POST \
  -H "Authorization: Bearer $service_jwt" \
  -H 'Content-Type: text/plain' \
  --data-binary 'hello-slim' \
  "http://127.0.0.1:$port/object/smoke-bucket/hello.txt" >/dev/null \
  || { container_logs "$container"; fail "storage object upload failed"; }
body="$(curl -fsS -H "Authorization: Bearer $service_jwt" \
  "http://127.0.0.1:$port/object/smoke-bucket/hello.txt")"
[[ "$body" == "hello-slim" ]] \
  || { container_logs "$container"; fail "storage object download mismatch: $body"; }

record_runtime_metrics "$container"
log "storage smoke passed"
