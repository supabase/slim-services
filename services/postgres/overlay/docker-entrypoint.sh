#!/usr/bin/sh
# CLI facade: `exec docker-entrypoint.sh postgres -D /etc/postgresql`.
# Starts as root like docker.io, then busybox-su to the probed uid.
# Init stays in entry.sh; this file does not extract upstream gosu.
set -eu

DROP_TO_NAME="${DROP_TO_NAME:-root}"

if [ "$(id -u)" = "0" ] && [ "$DROP_TO_NAME" != "root" ]; then
  exec /usr/bin/busybox su -s /usr/bin/sh "$DROP_TO_NAME" -c \
    'exec /usr/bin/sh /usr/local/bin/docker-entrypoint.sh "$@"' -- "$@"
fi

if [ "${1:-}" = "postgres" ]; then
  /usr/bin/sh /usr/local/bin/entry.sh --prepare
  shift
  GETKEY_SCRIPT="/opt/postgres/share/supabase-cli/config/pgsodium_getkey.sh"
  exec /opt/postgres/bin/postgres \
    -c "pgsodium.getkey_script=$GETKEY_SCRIPT" \
    -c "vault.getkey_script=$GETKEY_SCRIPT" \
    "$@"
fi

exec /usr/bin/sh /usr/local/bin/entry.sh "$@"
