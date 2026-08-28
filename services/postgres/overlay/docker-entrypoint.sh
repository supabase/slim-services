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

if pg_want_help "$@"; then
  if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
    set -- postgres "$@"
  fi
  exec /opt/postgres/bin/postgres "$@"
fi

if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
  set -- postgres -D /etc/postgresql "$@"
fi

if [ "$1" != "postgres" ]; then
  exec "$@"
fi

# busybox su -c puts the first operand in $0; a dummy keeps "$@" intact.
if [ "$(id -u)" = "0" ] && [ "$DROP_TO_NAME" != "root" ]; then
  exec /usr/bin/busybox su -s /usr/bin/sh "$DROP_TO_NAME" -c \
    'exec /usr/bin/sh /usr/local/bin/docker-entrypoint.sh "$@"' -- x "$@"
fi

/usr/bin/sh /usr/local/bin/entry.sh --prepare
shift
GETKEY_SCRIPT="/opt/postgres/share/supabase-cli/config/pgsodium_getkey.sh"
exec /opt/postgres/bin/postgres \
  -c "pgsodium.getkey_script=$GETKEY_SCRIPT" \
  -c "vault.getkey_script=$GETKEY_SCRIPT" \
  "$@"
