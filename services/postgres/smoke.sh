#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

image="${IMAGE:-}"
artifact_rootfs="${ARTIFACT_ROOTFS:-}"

if [[ -n "$image" && -n "$artifact_rootfs" ]]; then
  fail "set only one of IMAGE or ARTIFACT_ROOTFS"
fi
if [[ -z "$image" && -z "$artifact_rootfs" ]]; then
  fail "set IMAGE to smoke a Docker image, or ARTIFACT_ROOTFS to smoke an extracted artifact"
fi

if [[ -n "$artifact_rootfs" ]]; then
  # Host-process smoke for the portable postgres (upstream's
  # psql_17_cli_portable + pgvector via the slim-services overlay): initdb,
  # pg_ctl start, extension round-trip — no Docker anywhere.
  require_cmd python3

  pg_data_dir=""
  cleanup_postgres_smoke() {
    if [[ -n "$pg_data_dir" && -x "$artifact_rootfs/bin/pg_ctl" ]]; then
      "$artifact_rootfs/bin/pg_ctl" -D "$pg_data_dir/data" stop -m immediate >/dev/null 2>&1 || true
    fi
    rm -rf "$pg_data_dir"
    cleanup_smoke
  }
  trap cleanup_postgres_smoke EXIT

  for bin in postgres initdb pg_ctl psql; do
    [[ -x "$artifact_rootfs/bin/$bin" ]] || fail "postgres artifact binary missing: bin/$bin"
  done

  pg_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/postgres-smoke.XXXXXX")"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

  log "initdb (portable artifact)"
  "$artifact_rootfs/bin/initdb" -D "$pg_data_dir/data" -U supabase_admin --auth=trust \
    >"$pg_data_dir/initdb.log" 2>&1 \
    || { cat "$pg_data_dir/initdb.log" >&2; fail "initdb failed"; }

  log "starting postgres host process on port $port"
  # pg_cron/pg_net/pg_stat_statements need preloading (the CLI applies its
  # own config template with the same preload set).
  "$artifact_rootfs/bin/pg_ctl" -D "$pg_data_dir/data" -l "$pg_data_dir/postgres.log" \
    -o "-p $port -c listen_addresses=127.0.0.1 -k $pg_data_dir -c shared_preload_libraries=pg_stat_statements,pg_cron,pg_net -c cron.database_name=postgres" \
    start >/dev/null \
    || { cat "$pg_data_dir/postgres.log" >&2; fail "pg_ctl start failed"; }
  postgres_pid="$(head -1 "$pg_data_dir/data/postmaster.pid")"

  psql_host() {
    "$artifact_rootfs/bin/psql" -h 127.0.0.1 -p "$port" -U supabase_admin -d postgres \
      -v ON_ERROR_STOP=1 -qAt -c "$1"
  }

  start="$(date +%s)"
  while ! psql_host "SELECT 1" >/dev/null 2>&1; do
    if (( "$(date +%s)" - start >= 60 )); then
      cat "$pg_data_dir/postgres.log" >&2
      fail "portable postgres did not become ready"
    fi
    sleep 1
  done

  # The bundled CLI config template must carry the supautils allowlist the
  # docker.io image ships (appended at build from the source checkout's
  # ansible supautils.conf.j2); without it, supautils.privileged_extensions
  # is empty and the non-superuser postgres role cannot CREATE EXTENSION
  # pg_net on fresh databases (the CLI's shadow databases included). The
  # image smoke exercises this live; here the server runs without the
  # template, so assert the shipped file.
  log "checking the CLI config template carries the supautils allowlist"
  template="$artifact_rootfs/share/supabase-cli/config/postgresql.conf.template"
  grep -q "^supautils\.privileged_extensions = '[^']*pg_net" "$template" \
    || fail "postgresql.conf.template is missing pg_net in supautils.privileged_extensions"
  grep -q "^supautils\.privileged_extensions_superuser = 'supabase_admin'" "$template" \
    || fail "postgresql.conf.template is missing supautils.privileged_extensions_superuser"

  # The artifact ships the full PG17 extension set; create the preload-free
  # subset here. pgsodium/supabase_vault additionally need the pgsodium
  # getkey script from the CLI config bundle (exercised by the image smoke,
  # whose entrypoint wires it); pgaudit/pg_stat_monitor/pg_tle need a
  # shared_preload_libraries opt-in.
  log "creating the portable extension set (preload-free subset)"
  for ext in pgcrypto pgjwt pg_stat_statements vector pg_net pg_cron hypopg index_advisor pg_jsonschema pg_hashids http rum pgtap pgmq pg_partman pg_repack plpgsql_check postgis pgrouting pgroonga wrappers; do
    psql_host "CREATE EXTENSION IF NOT EXISTS $ext CASCADE" >/dev/null \
      || { cat "$pg_data_dir/postgres.log" >&2; fail "CREATE EXTENSION $ext failed"; }
  done

  log "pgvector round-trip"
  psql_host "CREATE TABLE IF NOT EXISTS smoke_vec(id serial primary key, v vector(3))" >/dev/null
  psql_host "INSERT INTO smoke_vec(v) VALUES ('[1,2,3]'), ('[4,5,6]')" >/dev/null
  nearest="$(psql_host "SELECT id FROM smoke_vec ORDER BY v <-> '[1,2,2]' LIMIT 1")"
  [[ "$nearest" == "1" ]] || fail "pgvector nearest-neighbour query returned $nearest, expected 1"

  # Postgres needs a longer settle than the 10s default (autovacuum /
  # checkpointer churn right after initdb + extension creation).
  SLIM_RUNTIME_SETTLE="${SLIM_RUNTIME_SETTLE:-60}" record_host_runtime_metrics "$postgres_pid"
  log "postgres smoke passed"
  exit 0
fi

require_cmd docker
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

# The derived image uses the CLI config templates: local socket + loopback
# auth is scram-sha-256, so psql needs the password.
psql_admin() {
  docker exec -e PGPASSWORD=postgres "$container" psql -h 127.0.0.1 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -qAt -c "$1"
}

log "checking local-dev config profile is active"
[[ "$(psql_admin "SHOW shared_buffers")" == "32MB" ]] || fail "expected shared_buffers=32MB"
[[ "$(psql_admin "SHOW jit")" == "off" ]] || fail "expected jit=off"
[[ "$(psql_admin "SHOW wal_level")" == "logical" ]] || fail "expected wal_level=logical"

# The migrations create postgres as a non-superuser (demoted in
# post-setup); with supautils preloaded, its CREATE EXTENSION only succeeds
# for extensions on supautils.privileged_extensions (run escalated as
# supautils.privileged_extensions_superuser). This is exactly what the CLI
# does on every fresh/shadow database when webhooks are on, so exercise it
# before the supabase_admin extension sweep below claims pg_net.
psql_postgres() {
  docker exec -e PGPASSWORD=postgres "$container" psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt -c "$1"
}

log "checking the supautils allowlist matches the docker.io image"
[[ "$(psql_admin "SHOW supautils.privileged_extensions")" == *pg_net* ]] \
  || fail "supautils.privileged_extensions does not include pg_net"
[[ "$(psql_admin "SELECT rolsuper FROM pg_roles WHERE rolname = 'postgres'")" == "f" ]] \
  || fail "expected the postgres role to be a demoted non-superuser"

log "creating pg_net as the non-superuser postgres role (CLI shadow-db path)"
psql_postgres "CREATE EXTENSION pg_net" >/dev/null \
  || { container_logs "$container"; fail "CREATE EXTENSION pg_net as postgres failed"; }

# The derived image ships the full PG17 extension set (everything the
# upstream image supports; timescaledb/plv8 do not support PG17), installed
# but NOT enabled — only the minimal shared_preload_libraries set is on by
# default, keeping the low-footprint profile. This list creates everything
# that works without extra preloads; pgaudit/pg_stat_monitor/pg_tle require
# a shared_preload_libraries opt-in (config change + restart) and
# supautils/safeupdate/plan_filter/wal2json are preload-only or plugin
# libraries with no extension to create. pgsodium/supabase_vault exercise
# the getkey wiring set up by the bundle's init script.
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

log "pgvector round-trip"
psql_admin "CREATE TABLE IF NOT EXISTS smoke_vec(id serial primary key, v vector(3))" >/dev/null
psql_admin "INSERT INTO smoke_vec(v) VALUES ('[1,2,3]'), ('[4,5,6]')" >/dev/null
[[ "$(psql_admin "SELECT id FROM smoke_vec ORDER BY v <-> '[1,2,2]' LIMIT 1")" == "1" ]] \
  || fail "pgvector nearest-neighbour query failed"

# Postgres needs a longer settle than the 10s default: right after initdb +
# migrations + extension creation, autovacuum/checkpointer are still working
# and a short settle records churn instead of steady state.
SLIM_RUNTIME_SETTLE="${SLIM_RUNTIME_SETTLE:-60}" record_runtime_metrics "$container"
log "postgres smoke passed"
