#!/usr/bin/sh
# Official postgres argv rules without extracting gosu:
# empty / leading '-' stays the server path; anything else is exec'd as-is
# (db dump / db pull pass `bash -c`). --help/--version exec postgres
# directly (no initdb); postgres only accepts those as argv[0].
set -eu

DROP_TO_NAME="${DROP_TO_NAME:-root}"

# /run is often tmpfs; create the docker.io socket dir before drop.
if [ "$(id -u)" = "0" ]; then
  mkdir -p /run/postgresql
  chown "${DROP_TO_UID:-0}:${DROP_TO_GID:-0}" /run/postgresql
  chmod 2775 /run/postgresql
fi

pg_want_help() {
  for arg in "$@"; do
    case "$arg" in
      -'?'|--help|--describe-config|-V|--version) return 0 ;;
    esac
  done
  return 1
}

# Help/version before -D rewrite: postgres only accepts those as argv[1].
# Only the server path — `bash --help` must stay exec-as-is.
if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
  if pg_want_help "$@"; then
    exec /opt/postgres/bin/postgres "$@"
  fi
  set -- postgres -D /etc/postgresql "$@"
fi

if [ "$1" != "postgres" ]; then
  exec "$@"
fi

if pg_want_help "$@"; then
  shift
  exec /opt/postgres/bin/postgres "$@"
fi

# CLI --from-backup writes schema.sql and a restore that runs it again.
# Truncate+chown while root: no mv applet, and postgres cannot rename in /etc.
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
schema_sql="${SUPABASE_POSTGRES_SCHEMA_FILE:-/etc/postgresql.schema.sql}"
schema_backup="${SUPABASE_POSTGRES_SCHEMA_BACKUP:-/tmp/slim-schema.sql}"
initdb_dir="${SUPABASE_POSTGRES_INITDB_DIR:-/docker-entrypoint-initdb.d}"
if [ "$(id -u)" = "0" ] && [ ! -s "$PGDATA/PG_VERSION" ] \
  && [ -s "$schema_sql" ] && [ -f "$initdb_dir/migrate.sh" ]; then
  cp "$schema_sql" "$schema_backup"
  : > "$schema_sql"
  # Sticky /tmp: drop-to must own the copy to restore and unlink it.
  chown "${DROP_TO_UID:-0}:${DROP_TO_GID:-0}" "$schema_backup" "$schema_sql"
fi

# busybox su -c puts the first operand in $0; a dummy keeps "$@" intact.
if [ "$(id -u)" = "0" ] && [ "$DROP_TO_NAME" != "root" ]; then
  exec /usr/bin/busybox su -s /usr/bin/sh "$DROP_TO_NAME" -c \
    'exec /usr/bin/sh /usr/local/bin/docker-entrypoint.sh "$@"' -- x "$@"
fi

# The artifact owns first boot, migrations and the final postgres exec. Remove
# the official executable/config-dir pair and preserve the remaining server
# options for the service command.
shift
if [ "${1:-}" = "-D" ]; then
  config_dir="${2:-}"
  [ -n "$config_dir" ] || { echo "postgres: -D requires a directory" >&2; exit 1; }
  export SUPABASE_POSTGRES_CONFIG_DIR="$config_dir"
  shift 2
fi
exec /usr/bin/sh /usr/local/bin/entry.sh "$@"
