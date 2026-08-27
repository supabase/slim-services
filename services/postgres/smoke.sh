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

  for bin in postgres initdb pg_ctl psql pg_dump pg_dumpall; do
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

  # The bundle's config is the docker.io recipe (ansible/files) assembled at
  # build with Dockerfile-supabase's own edits; the image smoke exercises it
  # live, and here the server runs without the templates, so assert the
  # shipped files: the supautils allowlist, the docker.io preload set, the
  # extension custom scripts, and the patched init script.
  log "checking the bundled config is the shared docker.io recipe"
  cfg_dir="$artifact_rootfs/share/supabase-cli/config"
  template="$cfg_dir/postgresql.conf.template"
  grep -q "^supautils\.privileged_extensions = '[^']*pg_net" "$cfg_dir/supautils.conf" \
    || fail "supautils.conf is missing pg_net in supautils.privileged_extensions"
  grep -q "^supautils\.privileged_extensions_superuser = 'supabase_admin'" "$cfg_dir/supautils.conf" \
    || fail "supautils.conf is missing supautils.privileged_extensions_superuser"
  grep -q "^session_preload_libraries = 'supautils'" "$template" \
    || fail "postgresql.conf.template is missing the docker.io session_preload_libraries"
  grep "^shared_preload_libraries" "$template" | grep -q pgaudit \
    || fail "postgresql.conf.template is missing the docker.io shared_preload_libraries set"
  grep -q "^include = 'supautils.conf'" "$template" \
    || fail "postgresql.conf.template is missing the relocated supautils include"
  grep -q "^port = 54322" "$template" \
    || fail "postgresql.conf.template is missing the local-dev divergence block"
  [[ -f "$artifact_rootfs/share/supabase-cli/extension-custom-scripts/before-create.sql" ]] \
    || fail "bundle is missing the extension custom scripts"
  init_script="$artifact_rootfs/share/supabase-cli/bin/supabase-postgres-init.sh"
  grep -q "stage-shared-config.sh" "$init_script" \
    || fail "init script is missing the shared-config staging hook"
  grep -q -- "--icu-locale=en_US.UTF-8" "$init_script" \
    || fail "init script is missing the docker.io initdb locale flags"

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

  # CLI contract: `db dump --role-only` runs pg_dumpall inside the stack.
  # Capture, then grep: `grep -q` exits at first match and its SIGPIPE would
  # fail the dump under pipefail.
  log "role-only dump (pg_dumpall)"
  roles_dump="$("$artifact_rootfs/bin/pg_dumpall" -h 127.0.0.1 -p "$port" -U supabase_admin --roles-only)" \
    || fail "pg_dumpall --roles-only failed"
  grep -q "CREATE ROLE" <<<"$roles_dump" \
    || fail "pg_dumpall --roles-only produced no roles"

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
[[ "$(psql_admin "SHOW max_connections")" == "100" ]] \
  || fail "expected max_connections=100 (docker.io parity)"

# CLI contract: `db dump --role-only` pipes pg_dumpall through the image's
# own toolbox (busybox uniq) — exercise the exact pipeline in-container.
log "role-only dump pipeline (pg_dumpall | uniq) inside the image"
docker exec -e PGPASSWORD=postgres "$container" \
  sh -c "pg_dumpall -h 127.0.0.1 -U supabase_admin --roles-only | uniq | grep 'CREATE ROLE' >/dev/null" \
  || { container_logs "$container"; fail "in-image pg_dumpall | uniq role-only pipeline failed"; }

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

# The shared docker.io recipe, live: session-preloaded supautils, the conf.d
# settings, replication capacity, ICU/en_US initdb, and loopback trust.
log "checking the shared docker.io recipe is active"
[[ "$(psql_admin "SHOW session_preload_libraries")" == "supautils" ]] \
  || fail "expected session_preload_libraries=supautils"
[[ "$(psql_admin "SHOW pg_net.username")" == "postgres" ]] \
  || fail "expected pg_net.username=postgres (conf.d)"
[[ "$(psql_admin "SHOW max_wal_senders")" == "10" ]] || fail "expected max_wal_senders=10"
[[ "$(psql_admin "SHOW lc_messages")" == "en_US.UTF-8" ]] || fail "expected lc_messages=en_US.UTF-8"
[[ "$(psql_admin "SELECT datlocprovider FROM pg_database WHERE datname = 'postgres'")" == "i" ]] \
  || fail "expected an ICU-provider database (docker.io initdb parity)"
psql_admin "SELECT pg_create_physical_replication_slot('smoke_slot')" >/dev/null \
  || fail "could not create a replication slot"
psql_admin "SELECT pg_drop_replication_slot('smoke_slot')" >/dev/null
docker exec "$container" psql -h 127.0.0.1 -U postgres -d postgres -qAt -c "SELECT 1" >/dev/null \
  || fail "expected passwordless loopback (docker.io pg_hba parity)"

# The extension custom scripts only run through supautils' non-superuser
# escalation, so create these as postgres (exactly how the CLI does) and
# assert the after-create grants the docker.io image applies.
log "checking extension custom scripts run on CREATE EXTENSION (as postgres)"
psql_postgres "CREATE EXTENSION pg_cron" >/dev/null \
  || { container_logs "$container"; fail "CREATE EXTENSION pg_cron as postgres failed"; }
[[ "$(psql_admin "SELECT has_schema_privilege('postgres', 'cron', 'USAGE')")" == "t" ]] \
  || fail "pg_cron after-create script did not grant cron schema usage to postgres"
# supabase_vault (with pgsodium) is created BY the bundled migrations — as
# superuser, identically on the docker.io image, so its post-create state is
# parity-by-construction and the escalation path cannot be exercised with
# it; assert the migrated state instead (pg_cron above is the
# custom-script proof).
[[ "$(psql_admin "SELECT count(*) FROM pg_extension WHERE extname = 'supabase_vault'")" == "1" ]] \
  || fail "supabase_vault missing after bundled migrations"

# Preload parity: pgaudit/pg_tle need shared_preload_libraries, which the
# shared recipe now provides (they were uncreatable on the old minimal set).
log "creating the preload-dependent extension pair (as postgres)"
for ext in pgaudit pg_tle; do
  psql_postgres "CREATE EXTENSION IF NOT EXISTS $ext CASCADE" >/dev/null \
    || { container_logs "$container"; fail "CREATE EXTENSION $ext failed"; }
done

# The derived image ships the full PG17 extension set (everything the
# upstream image supports; timescaledb/plv8 do not support PG17) with the
# docker.io shared_preload_libraries set active (shared recipe), so
# pgaudit/pg_tle are creatable too (exercised above, as postgres);
# pg_stat_monitor still needs a preload opt-in — docker.io does not preload
# it either. supautils/safeupdate/plan_filter/wal2json are preload-only or
# plugin libraries with no extension to create. pgsodium/supabase_vault
# exercise the getkey wiring set up by the bundle's init script.
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
