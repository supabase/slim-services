#!/bin/sh
# Service-owned PostgreSQL lifecycle for the portable Supabase bundle.
#
# The caller supplies instance state (PGDATA, credentials and server options).
# This command owns the immutable bundle's first-boot and migration contract:
# initialize an empty cluster, run the bundled migrations in an isolated
# temporary server, atomically record success, and then replace itself with
# the long-lived server.  It never removes a data directory.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
bundle_dir=$(CDPATH='' cd -- "$script_dir/.." && pwd -P)
bin_dir="$bundle_dir/bin"
init_script="$bundle_dir/share/supabase-cli/bin/supabase-postgres-init.sh"
migration_script="$bundle_dir/share/supabase-cli/migrations/migrate.sh"

export PGDATA="${PGDATA:-$PWD/postgres_data}"
export POSTGRES_USER="${POSTGRES_USER:-supabase_admin}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-postgres}"

config_dir="${SUPABASE_POSTGRES_CONFIG_DIR:-$PGDATA}"
init_pending="$PGDATA/.supabase-postgres-init-pending"
initdb_dir="${SUPABASE_POSTGRES_INITDB_DIR:-}"
schema_file="${SUPABASE_POSTGRES_SCHEMA_FILE:-}"
schema_backup="${SUPABASE_POSTGRES_SCHEMA_BACKUP:-}"
getkey_script="$bundle_dir/share/supabase-cli/config/pgsodium_getkey.sh"

socket_dir=
migration_log=
temp_server_started=0
init_attempted=0

# Keep command discovery deterministic for migrate.sh and user init scripts.
export PATH="$bin_dir${PATH:+:$PATH}"

restore_schema() {
  if [ -n "$schema_file" ] && [ -n "$schema_backup" ] && [ -s "$schema_backup" ]; then
    cp "$schema_backup" "$schema_file" || return 1
    # Keep the backup when unlinking fails; the restored source remains
    # recoverable and the next cleanup/start can retry the unlink.
    rm -f "$schema_backup" || return 1
  fi
}

temp_server_owned() {
  [ "$temp_server_started" = 1 ] || return 1
  [ -n "$socket_dir" ] || return 1
  if [ -f "$PGDATA/postmaster.opts" ] \
    && grep -F -q -- "$socket_dir" "$PGDATA/postmaster.opts"; then
    return 0
  fi
  if [ -f "$PGDATA/postmaster.pid" ] \
    && grep -F -q -- "$socket_dir" "$PGDATA/postmaster.pid"; then
    return 0
  fi
  return 1
}

write_pending_if_partial_init() {
  if [ "$init_attempted" = 1 ] && [ -s "$PGDATA/PG_VERSION" ] \
    && [ ! -e "$init_pending" ]; then
    (umask 077 && printf 'pending\n' >"$init_pending") || return 1
  fi
}

cleanup() {
  status=$?
  trap - 0 HUP INT TERM
  cleanup_error=0

  # A signal can arrive while pg_ctl -w start is still blocked. The command
  # is considered ours only when PostgreSQL recorded our unique socket path;
  # this protects an already-running server in the same PGDATA.
  if temp_server_owned; then
    "$bin_dir/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 \
      || cleanup_error=1
  fi

  if ! restore_schema; then
    echo "supabase-postgres: failed to restore schema backup $schema_backup" >&2
    cleanup_error=1
  fi
  if [ -n "$socket_dir" ]; then
    rm -rf "$socket_dir" || cleanup_error=1
  fi
  if ! write_pending_if_partial_init; then
    echo "supabase-postgres: failed to record incomplete initialization at $init_pending" >&2
    cleanup_error=1
  fi
  if [ "$status" -eq 0 ] && [ "$cleanup_error" -ne 0 ]; then
    status=1
  fi
  exit "$status"
}

trap cleanup 0
trap 'exit 143' HUP INT TERM

# The stack passes PostgreSQL options, rather than another executable or -D.
# Preserve the standard informational commands without touching PGDATA or any
# lifecycle witness (including a pending failed initialization).
case "${1:-}" in
  -\?|--help|--describe-config|-V|--version)
    exec "$bin_dir/postgres" "$@"
    ;;
esac

has_init_files=0
if [ -n "$initdb_dir" ] && [ -d "$initdb_dir" ]; then
  for file in "$initdb_dir"/*; do
    [ -f "$file" ] || continue
    has_init_files=1
    break
  done
fi

# A previous fresh start failed during initialization or bootstrap. Do not
# silently promote that partial cluster on a later invocation; the owner can
# inspect/fix the input and remove this explicit pending witness before retry.
if [ -e "$init_pending" ]; then
  echo "supabase-postgres: initialization is pending after an earlier failure; refusing to start $PGDATA until $init_pending is removed" >&2
  exit 1
fi

initialized=0
fresh=0
if [ -s "$PGDATA/PG_VERSION" ]; then
  initialized=1
fi

if [ "$initialized" = 0 ]; then
  [ -x "$init_script" ] || {
    echo "supabase-postgres: initialization script is missing: $init_script" >&2
    exit 1
  }
  init_attempted=1
  mkdir -p "$PGDATA"
  echo "supabase-postgres: initializing database in $PGDATA"
  # The upstream init script's final postgres exec is intentionally converted
  # into a config probe. This keeps its initdb/config/password behavior in the
  # versioned PostgreSQL source tree while leaving startup to this command.
  bash "$init_script" -C max_connections >/dev/null
  initialized=1
  fresh=1
fi

# PG_VERSION can be written before a first-boot process is interrupted. Keep
# the cluster untouched and fail closed rather than guessing whether the
# upstream init/config phase completed. Existing unmarked volumes retain the
# established startup path and do not replay the bootstrap bundle.
if [ "$fresh" = 1 ] \
  && { [ ! -s "$PGDATA/postgresql.conf" ] || [ ! -s "$PGDATA/pg_hba.conf" ] || [ ! -s "$PGDATA/pg_ident.conf" ]; }; then
  echo "supabase-postgres: initialized data is missing PostgreSQL config; refusing to discard $PGDATA" >&2
  exit 1
fi

# Record the complete fresh-boot phase only after upstream initdb and its
# config phase have succeeded. Writing this before initdb would make PGDATA
# non-empty and cause initdb itself to refuse the directory.
if [ "$fresh" = 1 ]; then
  (umask 077 && printf 'pending\n' >"$init_pending")
fi

if [ "$fresh" = 1 ]; then
  [ -f "$migration_script" ] || {
    echo "supabase-postgres: bundled migration script is missing: $migration_script" >&2
    exit 1
  }

  # Every invocation gets a private, short socket path. This is required for
  # multiple local stacks: Unix socket paths have a small platform limit and
  # must not share /tmp or a fixed port with another stack. Keep the template
  # fixed and short even when the caller's TMPDIR is deeply nested.
  socket_dir=$(mktemp -d /tmp/supabase-pg.XXXXXX)
  migration_log="$socket_dir/postgres.log"
  chmod 700 "$socket_dir"
  # Set this before -w start: SIGTERM can interrupt pg_ctl while PostgreSQL
  # has already written its ownership record.
  temp_server_started=1

  echo "supabase-postgres: running bundled migrations"
  if ! "$bin_dir/pg_ctl" -D "$PGDATA" -l "$migration_log" \
    -o "-c listen_addresses='' -c port=5432 -c unix_socket_directories='$socket_dir' -c unix_socket_permissions=0700" \
    -w start; then
    cat "$migration_log" >&2 2>/dev/null || true
    exit 1
  fi
  if ! temp_server_owned; then
    echo "supabase-postgres: could not prove ownership of the temporary server; refusing to continue" >&2
    exit 1
  fi

  # The migration and init-script environments intentionally stay in their
  # subshells; final server options must retain the caller's values.
  # shellcheck disable=SC2030,SC2031
  if ! (
    cd "$bundle_dir/share/supabase-cli/migrations"
    export POSTGRES_HOST="$socket_dir" POSTGRES_PORT=5432
    export PGHOST="$socket_dir" PGPORT=5432 PGDATABASE="$POSTGRES_DB"
    export PGPASSWORD="$POSTGRES_PASSWORD"
    sh "$migration_script"
  ); then
    cat "$migration_log" >&2 2>/dev/null || true
    restore_schema
    exit 1
  fi

  # The container adapter can temporarily hide the CLI --from-backup schema
  # while migrate.sh runs, because that script also probes this conventional
  # path. Restore it before optional initdb.d files, preserving the image's
  # established ordering without making container paths part of this command.
  restore_schema

  # Docker's initdb.d is an optional consumer input. It runs after the
  # immutable Supabase migrations, matching the official image contract.
  if [ "$fresh" = 1 ] && [ "$has_init_files" = 1 ]; then
    # shellcheck disable=SC2031
    (
      export POSTGRES_HOST="$socket_dir" POSTGRES_PORT=5432
      export PGHOST="$socket_dir" PGPORT=5432 PGDATABASE="$POSTGRES_DB"
      export PGPASSWORD="$POSTGRES_PASSWORD"
      for file in "$initdb_dir"/*; do
        [ -f "$file" ] || continue
        case "$file" in
          *.sh)
            if [ -x "$file" ]; then
              echo "supabase-postgres: running $file"
              "$file" || exit 1
            else
              echo "supabase-postgres: sourcing $file"
              # shellcheck disable=SC1090
              . "$file" || exit 1
            fi
            ;;
          *.sql)
            echo "supabase-postgres: running $file"
            "$bin_dir/psql" -h "$socket_dir" -p 5432 -U "$POSTGRES_USER" \
              -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 --no-password --no-psqlrc -f "$file" \
              || exit 1
            ;;
          *)
            echo "supabase-postgres: ignoring $file"
            ;;
        esac
      done
    ) || {
      restore_schema
      exit 1
    }
  fi

  # pg_ctl owns the temporary server only for the migration window. Stop it
  # before removing the pending witness; the final exec below replaces this
  # shell, so an EXIT trap cannot perform this cleanup after a successful start.
  if ! "$bin_dir/pg_ctl" -D "$PGDATA" -m fast -w stop; then
    cat "$migration_log" >&2 2>/dev/null || true
    exit 1
  fi
  temp_server_started=0
  rm -rf "$socket_dir"

  # Removing the pending witness is the commit point. All fresh bootstrap
  # work and schema restoration have completed, so an interrupted final exec
  # can safely use the existing-cluster path on the next start.
  rm -f "$init_pending"
  init_attempted=0
  trap - 0 HUP INT TERM
fi

echo "supabase-postgres: starting server"
exec "$bin_dir/postgres" -D "$config_dir" \
  -c "pgsodium.getkey_script=$getkey_script" \
  -c "vault.getkey_script=$getkey_script" "$@"
