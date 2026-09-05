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
marker="$PGDATA/.supabase-stack-migration-complete"
init_pending="$PGDATA/.supabase-postgres-init-pending"
initdb_dir="${SUPABASE_POSTGRES_INITDB_DIR:-}"
schema_file="${SUPABASE_POSTGRES_SCHEMA_FILE:-}"
schema_backup="${SUPABASE_POSTGRES_SCHEMA_BACKUP:-}"

# Keep command discovery deterministic for migrate.sh and user init scripts.
export PATH="$bin_dir${PATH:+:$PATH}"

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

# A previous fresh start reached the user init-file phase and failed. Do not
# silently promote that partial cluster on a later invocation; the owner can
# inspect/fix the input and remove this explicit pending witness before retry.
if [ -e "$init_pending" ]; then
  echo "supabase-postgres: initialization is pending after an earlier failure; refusing to start $PGDATA until $init_pending is removed" >&2
  exit 1
fi

if [ -e "$marker" ]; then
  marker_contents=$(cat "$marker")
  [ "$marker_contents" = completed ] || {
    echo "supabase-postgres: refusing invalid migration marker: $marker" >&2
    exit 1
  }
  migrated=1
else
  migrated=0
fi

initialized=0
fresh=0
if [ -s "$PGDATA/PG_VERSION" ]; then
  initialized=1
elif [ "$migrated" = 1 ]; then
  echo "supabase-postgres: migration marker exists without PG_VERSION" >&2
  exit 1
fi

if [ "$initialized" = 0 ]; then
  [ -x "$init_script" ] || {
    echo "supabase-postgres: initialization script is missing: $init_script" >&2
    exit 1
  }
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
# upstream init/config phase completed.
if [ ! -s "$PGDATA/postgresql.conf" ] || [ ! -s "$PGDATA/pg_hba.conf" ] || [ ! -s "$PGDATA/pg_ident.conf" ]; then
  echo "supabase-postgres: initialized data is missing PostgreSQL config; refusing to discard $PGDATA" >&2
  exit 1
fi

if [ "$fresh" = 1 ] && [ "$has_init_files" = 1 ]; then
  # Record the user-init phase only after upstream initdb and its config phase
  # have succeeded. Writing this before initdb would make PGDATA non-empty and
  # cause initdb itself to refuse the directory.
  (umask 077 && printf 'pending\n' >"$init_pending")
fi

restore_schema() {
  if [ -n "$schema_file" ] && [ -n "$schema_backup" ] && [ -s "$schema_backup" ]; then
    cp "$schema_backup" "$schema_file"
    rm -f "$schema_backup"
  fi
}

if [ "$migrated" = 0 ]; then
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
  temp_started=0

  cleanup() {
    status=$?
    if [ "$temp_started" = 1 ]; then
      "$bin_dir/pg_ctl" -D "$PGDATA" -m fast -w stop >/dev/null 2>&1 || true
    fi
    rm -rf "$socket_dir" "$migration_log"
    exit "$status"
  }
  trap cleanup 0
  trap 'exit 143' HUP INT TERM

  echo "supabase-postgres: running bundled migrations"
  "$bin_dir/pg_ctl" -D "$PGDATA" -l "$migration_log" \
    -o "-c listen_addresses='' -c port=5432 -c unix_socket_directories='$socket_dir' -c unix_socket_permissions=0700" \
    -w start \
    || {
      cat "$migration_log" >&2 2>/dev/null || true
      exit 1
    }
  temp_started=1

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
  # before committing the marker; the final exec below replaces this shell, so
  # an EXIT trap cannot perform this cleanup after a successful start.
  if ! "$bin_dir/pg_ctl" -D "$PGDATA" -m fast -w stop; then
    cat "$migration_log" >&2 2>/dev/null || true
    exit 1
  fi
  temp_started=0
  rm -rf "$socket_dir"
  trap - 0 HUP INT TERM

  # Once all user init files have succeeded, remove the pending witness before
  # publishing migration success. If interrupted in between, the migrations
  # are safely retried while already-complete initdb.d input is not replayed.
  if [ "$fresh" = 1 ] && [ "$has_init_files" = 1 ]; then
    rm -f "$init_pending"
  fi

  # The rename is the commit point. An interrupted or failed migration leaves
  # no marker, so the next start retries the idempotent bundle migrations.
  marker_parent=$(dirname -- "$marker")
  mkdir -p "$marker_parent"
  marker_tmp="$marker.$$"
  (umask 077 && printf 'completed\n' >"$marker_tmp")
  mv -f "$marker_tmp" "$marker"
fi

echo "supabase-postgres: starting server"
exec "$bin_dir/postgres" -D "$config_dir" "$@"
