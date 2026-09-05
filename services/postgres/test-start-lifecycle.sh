#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$ROOT_DIR/services/postgres/nix/packages/postgres-start.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/postgres-start-fixture.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'postgres-start fixture: %s\n' "$1" >&2
  exit 1
}

setup_fixture() {
  local name="$1"
  fixture_dir="$test_root/$name"
  bundle="$fixture_dir/bundle"
  data="$fixture_dir/data"
  event_log="$fixture_dir/events"
  pgctl_event_log="$fixture_dir/pgctl-events"
  socket_log="$fixture_dir/socket"
  postgres_exec_log="$fixture_dir/postgres-exec"
  mkdir -p "$bundle/bin" "$bundle/share/supabase-cli/bin" \
    "$bundle/share/supabase-cli/migrations" "$bundle/share/supabase-cli/config" \
    "$data"

  cp "$HELPER" "$bundle/bin/supabase-postgres-start"

  cat >"$bundle/bin/postgres" <<'EOF'
#!/bin/sh
set -eu
if [ -n "${POSTGRES_EXEC_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$POSTGRES_EXEC_LOG"
fi
exit "${POSTGRES_EXIT:-0}"
EOF

  cat >"$bundle/bin/pg_ctl" <<'EOF'
#!/bin/sh
set -eu
data="${PGDATA:?}"
opts=
mode=
expect=
for arg do
  if [ -n "$expect" ]; then
    case "$expect" in
      data) data="$arg" ;;
      log) : ;;
      opts) opts="$arg" ;;
    esac
    expect=
    continue
  fi
  case "$arg" in
    -D) expect=data ;;
    -l) expect=log ;;
    -o) expect=opts ;;
    start|stop) mode="$arg" ;;
  esac
done
mkdir -p "$data"
printf '%s\n' "$mode" >>"${PGCTL_EVENT_LOG:?}"
case "$mode" in
  start)
    if [ "${PGCTL_EXISTING:-0}" = 1 ]; then
      printf 'existing server\n' >"$data/postmaster.opts"
      exit 1
    fi
    socket="$(printf '%s\n' "$opts" | sed -n "s/.*unix_socket_directories='\([^']*\)'.*/\1/p")"
    printf '%s\n' "$opts" >"$data/postmaster.opts"
    printf '%s\n' "$socket" >"$data/postmaster.pid"
    printf '%s\n' "$socket" >"${PGCTL_SOCKET_LOG:?}"
    if [ -n "${PGCTL_READY:-}" ]; then
      : >"$PGCTL_READY"
    fi
    if [ "${PGCTL_BLOCK:-0}" = 1 ]; then
      i=0
      while [ ! -e "${PGCTL_STOP_REQUEST:?}" ] && [ "$i" -lt 3 ]; do
        sleep 1
        i=$((i + 1))
      done
      exit 143
    fi
    ;;
  stop)
    if [ -n "${PGCTL_STOP_REQUEST:-}" ]; then
      : >"$PGCTL_STOP_REQUEST"
    fi
    rm -f "$data/postmaster.pid"
    ;;
esac
EOF

  cat >"$bundle/share/supabase-cli/bin/supabase-postgres-init.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bundle_dir="$(cd "$script_dir/../../.." && pwd)"
printf '%s\n' init >>"${EVENT_LOG:?}"
mkdir -p "$PGDATA"
printf '17\n' >"$PGDATA/PG_VERSION"
for config in postgresql.conf pg_hba.conf pg_ident.conf; do
  printf '# fixture\n' >"$PGDATA/$config"
done
if [ "${INIT_FAIL:-0}" = 1 ]; then
  exit 17
fi
exec "$bundle_dir/bin/postgres" -D "$PGDATA" "$@"
EOF

  cat >"$bundle/share/supabase-cli/migrations/migrate.sh" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' migrate >>"${EVENT_LOG:?}"
if [ "${MIGRATE_FAIL:-0}" = 1 ]; then
  exit 17
fi
EOF

  chmod 0755 "$bundle/bin/postgres" "$bundle/bin/pg_ctl" \
    "$bundle/share/supabase-cli/bin/supabase-postgres-init.sh" \
    "$bundle/share/supabase-cli/migrations/migrate.sh"
  : >"$event_log"
  : >"$pgctl_event_log"
  : >"$postgres_exec_log"
  export PGDATA="$data"
  export POSTGRES_USER=supabase_admin POSTGRES_PASSWORD=postgres POSTGRES_DB=postgres
  export EVENT_LOG="$event_log" PGCTL_EVENT_LOG="$pgctl_event_log"
  export PGCTL_SOCKET_LOG="$socket_log" POSTGRES_EXEC_LOG="$postgres_exec_log"
  export PATH="/usr/bin:/bin"
  unset INIT_FAIL MIGRATE_FAIL PGCTL_EXISTING PGCTL_BLOCK PGCTL_READY PGCTL_STOP_REQUEST
  unset SUPABASE_POSTGRES_CONFIG_DIR SUPABASE_POSTGRES_INITDB_DIR
  unset SUPABASE_POSTGRES_SCHEMA_FILE SUPABASE_POSTGRES_SCHEMA_BACKUP
}

run_start() {
  "$bundle/bin/supabase-postgres-start" "$@"
}

count_event() {
  local event="$1"
  grep -c "^$event$" "$event_log" || true
}

assert_pending() {
  [ -e "$data/.supabase-postgres-init-pending" ] \
    || fail "missing pending witness in $data"
}

printf 'test existing unmarked cluster skips bootstrap\n'
setup_fixture existing-unmarked
printf '17\n' >"$data/PG_VERSION"
run_start -p 6543 || fail "existing unmarked cluster did not start"
[ "$(count_event init)" = 0 ] || fail "existing cluster reran upstream init"
[ "$(count_event migrate)" = 0 ] || fail "existing cluster reran bundled migrations"

printf 'test fresh migration failure blocks retry\n'
setup_fixture migration-failure
export MIGRATE_FAIL=1
if run_start; then
  fail "migration failure unexpectedly succeeded"
fi
unset MIGRATE_FAIL
assert_pending
[ "$(count_event migrate)" = 1 ] || fail "migration fixture did not run once"
if run_start; then
  fail "pending migration was accepted on retry"
fi
[ "$(count_event migrate)" = 1 ] || fail "pending retry reran migration"

printf 'test upstream init failure writes pending witness and blocks retry\n'
setup_fixture init-failure
export INIT_FAIL=1
if run_start; then
  fail "upstream init failure unexpectedly succeeded"
fi
unset INIT_FAIL
assert_pending
[ "$(count_event init)" = 1 ] || fail "init fixture did not run once"
if run_start; then
  fail "partial upstream init was accepted on retry"
fi
[ "$(count_event init)" = 1 ] || fail "partial init retry reran upstream init"

printf 'test early start failure restores hidden schema without stopping existing server\n'
setup_fixture schema-restore
schema_file="$fixture_dir/schema.sql"
schema_backup="$fixture_dir/schema.backup"
printf 'schema-body\n' >"$schema_file"
cp "$schema_file" "$schema_backup"
: >"$schema_file"
export SUPABASE_POSTGRES_SCHEMA_FILE="$schema_file"
export SUPABASE_POSTGRES_SCHEMA_BACKUP="$schema_backup"
export PGCTL_EXISTING=1
if run_start; then
  fail "existing-server start failure unexpectedly succeeded"
fi
unset PGCTL_EXISTING SUPABASE_POSTGRES_SCHEMA_FILE SUPABASE_POSTGRES_SCHEMA_BACKUP
[ "$(cat "$schema_file")" = 'schema-body' ] || fail "schema backup was not restored"
[ ! -e "$schema_backup" ] || fail "restored schema backup was not removed"
if grep -q '^stop$' "$pgctl_event_log"; then
  fail "existing server was stopped after unowned start failure"
fi

printf 'test failed schema restore retains backup\n'
setup_fixture schema-restore-failure
schema_file="$fixture_dir/missing/schema.sql"
schema_backup="$fixture_dir/schema.backup"
printf 'schema-body\n' >"$schema_backup"
export SUPABASE_POSTGRES_SCHEMA_FILE="$schema_file"
export SUPABASE_POSTGRES_SCHEMA_BACKUP="$schema_backup"
export PGCTL_EXISTING=1
if run_start; then
  fail "schema restore failure fixture unexpectedly succeeded"
fi
unset PGCTL_EXISTING SUPABASE_POSTGRES_SCHEMA_FILE SUPABASE_POSTGRES_SCHEMA_BACKUP
[ -e "$schema_backup" ] || fail "failed schema restore discarded backup"

printf 'test TERM during start stops only the owned temporary server\n'
setup_fixture term-start
export PGCTL_BLOCK=1 PGCTL_READY="$fixture_dir/ready" PGCTL_STOP_REQUEST="$fixture_dir/stop"
"$bundle/bin/supabase-postgres-start" >"$fixture_dir/output" 2>&1 &
helper_pid=$!
for _ in $(seq 1 50); do
  [ -e "$fixture_dir/ready" ] && break
  sleep 0.1
done
[ -e "$fixture_dir/ready" ] || fail "fixture pg_ctl did not enter start window"
kill -TERM "$helper_pid"
set +e
wait "$helper_pid"
helper_status=$?
set -e
[ "$helper_status" -ne 0 ] || fail "TERM during start unexpectedly succeeded"
grep -q '^stop$' "$pgctl_event_log" \
  || fail "TERM during owned start did not stop temporary server"
assert_pending
socket_path="$(cat "$socket_log")"
[ -n "$socket_path" ] && [ ! -e "$socket_path" ] \
  || fail "TERM cleanup leaked temporary socket directory"

printf 'test existing server is never stopped when ownership is unproven\n'
setup_fixture existing-server
export PGCTL_EXISTING=1
if run_start; then
  fail "existing-server conflict unexpectedly succeeded"
fi
unset PGCTL_EXISTING
if grep -q '^stop$' "$pgctl_event_log"; then
  fail "unowned existing server was stopped"
fi
assert_pending

printf 'test successful bootstrap explicitly cleans temporary state before exec\n'
setup_fixture successful-start
run_start -p 6543 || fail "successful fixture start failed"
[ ! -e "$data/.supabase-postgres-init-pending" ] \
  || fail "successful bootstrap retained pending witness"
socket_path="$(cat "$socket_log")"
[ -n "$socket_path" ] && [ ! -e "$socket_path" ] \
  || fail "successful start leaked temporary socket directory"
grep -q '^start$' "$pgctl_event_log" || fail "successful start did not start temp server"
grep -q '^stop$' "$pgctl_event_log" || fail "successful start did not stop temp server"
grep -q 'pgsodium.getkey_script=' "$postgres_exec_log" \
  || fail "final exec omitted pgsodium getkey override"

printf 'postgres-start fixture tests passed\n'
