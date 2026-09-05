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
  server_event_log="$fixture_dir/server-events"
  socket_log="$fixture_dir/socket"
  postgres_exec_log="$fixture_dir/postgres-exec"
  mkdir -p "$bundle/bin" "$bundle/share/supabase-cli/bin" \
    "$bundle/share/supabase-cli/migrations" "$bundle/share/supabase-cli/config" \
    "$data"

  cp "$HELPER" "$bundle/bin/supabase-postgres-start"

  cat >"$bundle/bin/postgres" <<'EOF'
#!/usr/bin/env python3
import os
import signal
import sys
import time

args = sys.argv[1:]
exec_log = os.environ.get("POSTGRES_EXEC_LOG")
if exec_log:
    with open(exec_log, "a", encoding="utf-8") as stream:
        stream.write("%s\n" % " ".join(args))
if args and args[0] == "-C":
    raise SystemExit(int(os.environ.get("POSTGRES_EXIT", "0")))

data = os.environ["PGDATA"]
socket = ""
for index, arg in enumerate(args[:-1]):
    if arg == "-c" and args[index + 1].startswith("unix_socket_directories="):
        socket = args[index + 1].split("=", 1)[1]

if not socket:
    raise SystemExit(int(os.environ.get("POSTGRES_EXIT", "0")))

with open(os.environ["SERVER_EVENT_LOG"], "a", encoding="utf-8") as stream:
    stream.write("start\n")
if os.environ.get("SERVER_EXISTING") == "1":
    with open(os.path.join(data, "postmaster.opts"), "w", encoding="utf-8") as stream:
        stream.write("existing server\n")
    raise SystemExit(1)

with open(os.path.join(data, "postmaster.opts"), "w", encoding="utf-8") as stream:
    stream.write("unix_socket_directories=%s\n" % socket)
with open(os.path.join(data, "postmaster.pid"), "w", encoding="utf-8") as stream:
    stream.write("%s\n" % socket)
with open(os.environ["SERVER_SOCKET_LOG"], "w", encoding="utf-8") as stream:
    stream.write("%s\n" % socket)
ready = os.environ.get("SERVER_READY")
if ready:
    open(ready, "a", encoding="utf-8").close()

def stop(_signum, _frame):
    with open(os.environ["SERVER_EVENT_LOG"], "a", encoding="utf-8") as stream:
        stream.write("stop\n")
    try:
        os.unlink(os.path.join(data, "postmaster.pid"))
    except FileNotFoundError:
        pass
    raise SystemExit(0)

for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signal_number, stop)
while True:
    time.sleep(1)
EOF

  cat >"$bundle/bin/pg_isready" <<'EOF'
#!/bin/sh
set -eu
socket=
expect=
for arg do
  if [ -n "$expect" ]; then
    [ "$expect" = host ] && socket="$arg"
    expect=
    continue
  fi
  [ "$arg" = -h ] && expect=host
done
[ -n "$socket" ] && [ -e "${PGDATA:?}/postmaster.pid" ] \
  && [ "${SERVER_WAIT_FOR_READINESS:-0}" != 1 ] \
  && [ "$(cat "$PGDATA/postmaster.pid")" = "$socket" ]
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
trap 'exit 143' HUP INT TERM
printf '%s\n' migrate >>"${EVENT_LOG:?}"
if [ "${MIGRATE_FAIL:-0}" = 1 ]; then
  exit 17
fi
if [ "${MIGRATE_BLOCK:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt "${MIGRATE_BLOCK_SECONDS:-30}" ]; do
    sleep 1
    i=$((i + 1))
  done
fi
EOF

  chmod 0755 "$bundle/bin/postgres" "$bundle/bin/pg_isready" \
    "$bundle/share/supabase-cli/bin/supabase-postgres-init.sh" \
    "$bundle/share/supabase-cli/migrations/migrate.sh"
  : >"$event_log"
  : >"$server_event_log"
  : >"$postgres_exec_log"
  export PGDATA="$data"
  export POSTGRES_USER=supabase_admin POSTGRES_PASSWORD=postgres POSTGRES_DB=postgres
  export EVENT_LOG="$event_log" SERVER_EVENT_LOG="$server_event_log"
  export SERVER_SOCKET_LOG="$socket_log" POSTGRES_EXEC_LOG="$postgres_exec_log"
  export PATH="/usr/bin:/bin"
  unset INIT_FAIL MIGRATE_FAIL MIGRATE_BLOCK MIGRATE_BLOCK_SECONDS \
    SERVER_EXISTING SERVER_READY
  unset SERVER_WAIT_FOR_READINESS
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
printf 'existing server\n' >"$data/postmaster.opts"
run_start -p 6543 || fail "existing unmarked cluster did not start"
[ "$(count_event init)" = 0 ] || fail "existing cluster reran upstream init"
[ "$(count_event migrate)" = 0 ] || fail "existing cluster reran bundled migrations"

printf 'test initialized data without startup record fails closed\n'
setup_fixture interrupted-unwitnessed
printf '17\n' >"$data/PG_VERSION"
printf 'valuable data\n' >"$data/valuable-data"
if run_start; then
  fail "unwitnessed initialized data unexpectedly started"
fi
[ -e "$data/valuable-data" ] || fail "unwitnessed data was deleted"
[ "$(count_event init)" = 0 ] || fail "unwitnessed data reran upstream init"
[ "$(count_event migrate)" = 0 ] || fail "unwitnessed data reran bundled migrations"

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
export SERVER_EXISTING=1
if run_start; then
  fail "existing-server start failure unexpectedly succeeded"
fi
unset SERVER_EXISTING SUPABASE_POSTGRES_SCHEMA_FILE SUPABASE_POSTGRES_SCHEMA_BACKUP
[ "$(cat "$schema_file")" = 'schema-body' ] || fail "schema backup was not restored"
[ ! -e "$schema_backup" ] || fail "restored schema backup was not removed"
if grep -q '^stop$' "$server_event_log"; then
  fail "existing server was stopped after unowned start failure"
fi

printf 'test failed schema restore retains backup\n'
setup_fixture schema-restore-failure
schema_file="$fixture_dir/missing/schema.sql"
schema_backup="$fixture_dir/schema.backup"
printf 'schema-body\n' >"$schema_backup"
export SUPABASE_POSTGRES_SCHEMA_FILE="$schema_file"
export SUPABASE_POSTGRES_SCHEMA_BACKUP="$schema_backup"
export SERVER_EXISTING=1
if run_start; then
  fail "schema restore failure fixture unexpectedly succeeded"
fi
unset SERVER_EXISTING SUPABASE_POSTGRES_SCHEMA_FILE SUPABASE_POSTGRES_SCHEMA_BACKUP
[ -e "$schema_backup" ] || fail "failed schema restore discarded backup"

printf 'test TERM during start stops only the owned temporary server before deadline\n'
setup_fixture term-start
export SERVER_READY="$fixture_dir/ready" SERVER_WAIT_FOR_READINESS=1
"$bundle/bin/supabase-postgres-start" >"$fixture_dir/output" 2>&1 &
helper_pid=$!
for _ in $(seq 1 50); do
  [ -e "$fixture_dir/ready" ] && break
  sleep 0.1
done
[ -e "$fixture_dir/ready" ] || fail "fixture postgres did not enter start window"
kill -TERM "$helper_pid"
set +e
for _ in $(seq 1 50); do
  if ! kill -0 "$helper_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$helper_pid" 2>/dev/null; then
  kill -KILL "$helper_pid" 2>/dev/null || true
  wait "$helper_pid" 2>/dev/null || true
  set -e
  fail "TERM during start did not exit before deadline"
fi
wait "$helper_pid"
helper_status=$?
set -e
[ "$helper_status" -ne 0 ] || fail "TERM during start unexpectedly succeeded"
grep -q '^stop$' "$server_event_log" \
  || fail "TERM during owned start did not stop temporary server"
assert_pending
socket_path="$(cat "$socket_log")"
[ -n "$socket_path" ] && [ ! -e "$socket_path" ] \
  || fail "TERM cleanup leaked temporary socket directory"

printf 'test TERM during migration exits before deadline\n'
setup_fixture term-migration
export MIGRATE_BLOCK=1 MIGRATE_BLOCK_SECONDS=30
"$bundle/bin/supabase-postgres-start" >"$fixture_dir/output" 2>&1 &
helper_pid=$!
for _ in $(seq 1 50); do
  if grep -q '^migrate$' "$event_log"; then
    break
  fi
  sleep 0.1
done
grep -q '^migrate$' "$event_log" || fail "fixture migration did not enter start window"
kill -TERM "$helper_pid"
set +e
for _ in $(seq 1 50); do
  if ! kill -0 "$helper_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if kill -0 "$helper_pid" 2>/dev/null; then
  kill -KILL "$helper_pid" 2>/dev/null || true
  wait "$helper_pid" 2>/dev/null || true
  set -e
  fail "TERM during migration did not exit before deadline"
fi
wait "$helper_pid"
helper_status=$?
set -e
[ "$helper_status" -ne 0 ] || fail "TERM during migration unexpectedly succeeded"
grep -q '^stop$' "$server_event_log" \
  || fail "TERM during migration did not stop temporary server"
assert_pending

printf 'test existing server is never stopped when ownership is unproven\n'
setup_fixture existing-server
export SERVER_EXISTING=1
if run_start; then
  fail "existing-server conflict unexpectedly succeeded"
fi
unset SERVER_EXISTING
if grep -q '^stop$' "$server_event_log"; then
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
grep -q '^start$' "$server_event_log" || fail "successful start did not start temp server"
grep -q '^stop$' "$server_event_log" || fail "successful start did not stop temp server"
grep -q 'pgsodium.getkey_script=' "$postgres_exec_log" \
  || fail "final exec omitted pgsodium getkey override"

printf 'postgres-start fixture tests passed\n'
