#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
image="${IMAGE:?set IMAGE to the image tag to smoke test}"
ensure_image "$image"

container="postgres-smoke-$RUN_ID"
run_container \
  "$container" \
  -e POSTGRES_PASSWORD=postgres \
  "$image"

log "waiting for postgres to accept connections (init + migrations)"
start="$(date +%s)"
while true; do
  if docker exec "$container" pg_isready -h 127.0.0.1 -U supabase_admin >/dev/null 2>&1; then
    break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || printf false)" != "true" ]]; then
    container_logs "$container"
    fail "postgres container exited during startup"
  fi
  if (( "$(date +%s)" - start >= 240 )); then
    container_logs "$container"
    fail "postgres did not become ready in time"
  fi
  sleep 2
done

# Give the entrypoint time to finish init scripts/migrations after first ready.
sleep 5
docker exec "$container" pg_isready -h 127.0.0.1 -U supabase_admin >/dev/null 2>&1 \
  || { container_logs "$container"; fail "postgres not ready after migrations"; }

psql_admin() {
  docker exec "$container" psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -qAt -c "$1"
}

log "checking local-dev config profile is active"
[[ "$(psql_admin "SHOW shared_buffers")" == "32MB" ]] || fail "expected shared_buffers=32MB"
[[ "$(psql_admin "SHOW jit")" == "off" ]] || fail "expected jit=off"
[[ "$(psql_admin "SHOW wal_level")" == "logical" ]] || fail "expected wal_level=logical"

log "creating local-dev extension set"
extensions=(
  pgcrypto
  pgjwt
  '"uuid-ossp"'
  pg_trgm
  hstore
  pg_stat_statements
  pg_graphql
  pg_net
  pg_cron
  vector
  hypopg
  index_advisor
  pg_jsonschema
  pg_hashids
  http
  pgaudit
  pg_tle
  rum
  pgsodium
  supabase_vault
  pgtap
)
for ext in "${extensions[@]}"; do
  psql_admin "CREATE EXTENSION IF NOT EXISTS $ext CASCADE" >/dev/null \
    || { container_logs "$container"; fail "CREATE EXTENSION $ext failed"; }
done
log "all ${#extensions[@]} extensions created"

log "checking denied extensions are really gone"
if psql_admin "CREATE EXTENSION postgis" >/dev/null 2>&1; then
  fail "postgis unexpectedly present in slim image"
fi

log "basic SQL round-trip"
psql_admin "CREATE TABLE IF NOT EXISTS smoke_check(id serial primary key, v text)" >/dev/null
psql_admin "INSERT INTO smoke_check(v) VALUES ('ok')" >/dev/null
[[ "$(psql_admin "SELECT v FROM smoke_check LIMIT 1")" == "ok" ]] || fail "basic SQL round-trip failed"

record_runtime_metrics "$container"
log "postgres smoke passed"
