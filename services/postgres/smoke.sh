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
wait_for_postgres 240 "$container" supabase_admin \
  || fail "postgres did not become ready in time"

# The entrypoint boots a TEMPORARY server for init scripts/migrations, stops
# it, then starts the real one — the first ready signal can be the temporary
# instance. Grace-wait and re-check so we talk to the final server.
sleep 5
wait_for_postgres 60 "$container" supabase_admin \
  || fail "postgres not ready after migrations"

psql_admin() {
  docker exec "$container" psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -qAt -c "$1"
}

log "checking local-dev config profile is active"
[[ "$(psql_admin "SHOW shared_buffers")" == "32MB" ]] || fail "expected shared_buffers=32MB"
[[ "$(psql_admin "SHOW jit")" == "off" ]] || fail "expected jit=off"
[[ "$(psql_admin "SHOW wal_level")" == "logical" ]] || fail "expected wal_level=logical"

log "creating the supported extension set (including the heavy families)"
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
  pgmq
  pg_partman
  pg_repack
  plpgsql_check
  postgis
  postgis_topology
  address_standardizer
  pgrouting
  pgroonga
  wrappers
)
for ext in "${extensions[@]}"; do
  psql_admin "CREATE EXTENSION IF NOT EXISTS $ext CASCADE" >/dev/null \
    || { container_logs "$container"; fail "CREATE EXTENSION $ext failed"; }
done
log "all ${#extensions[@]} extensions created"

log "basic SQL round-trip"
psql_admin "CREATE TABLE IF NOT EXISTS smoke_check(id serial primary key, v text)" >/dev/null
psql_admin "INSERT INTO smoke_check(v) VALUES ('ok')" >/dev/null
[[ "$(psql_admin "SELECT v FROM smoke_check LIMIT 1")" == "ok" ]] || fail "basic SQL round-trip failed"

# Postgres needs a longer settle than the 10s default: right after initdb +
# migrations + extension creation, autovacuum/checkpointer are still working
# and a short settle records churn instead of steady state.
SLIM_RUNTIME_SETTLE="${SLIM_RUNTIME_SETTLE:-60}" record_runtime_metrics "$container"
log "postgres smoke passed"
