#!/usr/bin/sh
# Official postgres argv rules without extracting gosu:
# empty / leading '-' stays the server path; anything else is exec'd as-is
# (db dump / db pull pass `bash -c`).
set -eu

DROP_TO_NAME="${DROP_TO_NAME:-root}"

# /run is often tmpfs; create the docker.io socket dir before drop.
if [ "$(id -u)" = "0" ]; then
  mkdir -p /run/postgresql
  chown "${DROP_TO_UID:-0}:${DROP_TO_GID:-0}" /run/postgresql
  chmod 2775 /run/postgresql
fi

if [ -z "${1:-}" ] || [ "${1#-}" != "$1" ]; then
  set -- postgres -D /etc/postgresql "$@"
fi

if [ "$1" != "postgres" ]; then
  exec "$@"
fi

if [ "$(id -u)" = "0" ] && [ "$DROP_TO_NAME" != "root" ]; then
  exec /usr/bin/busybox su -s /usr/bin/sh "$DROP_TO_NAME" -c \
    'exec /usr/bin/sh /usr/local/bin/docker-entrypoint.sh "$@"' -- "$@"
fi

/usr/bin/sh /usr/local/bin/entry.sh --prepare
shift
GETKEY_SCRIPT="/opt/postgres/share/supabase-cli/config/pgsodium_getkey.sh"
exec /opt/postgres/bin/postgres \
  -c "pgsodium.getkey_script=$GETKEY_SCRIPT" \
  -c "vault.getkey_script=$GETKEY_SCRIPT" \
  "$@"
