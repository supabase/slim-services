#!/bin/sh
# Derived-image entrypoint: the image is the portable postgres artifact
# (/opt/postgres) plus this wiring (HOST_NATIVE_PLAN.md, native-first — no
# exceptions). First boot delegates initialization to the bundle's own
# supabase-postgres-init.sh (initdb, CLI config templates with the pgsodium
# getkey script wired, superuser password, bundled init scripts), then this
# script applies the docker-shaped settings, runs the supabase migrations,
# and starts the server.
set -eu

DROP_TO_NAME="${DROP_TO_NAME:-root}"

# Image USER is unset (root), matching docker.io. Postgres refuses euid 0.
if [ "$(id -u)" = "0" ] && [ "$DROP_TO_NAME" != "root" ]; then
  exec /usr/bin/busybox su -s /usr/bin/sh "$DROP_TO_NAME" -c \
    'exec /usr/bin/sh /usr/local/bin/entry.sh "$@"' -- "$@"
fi

prepare_only=0
if [ "${1:-}" = "--prepare" ]; then
  prepare_only=1
  shift
fi

BUNDLE=/opt/postgres
export PGDATA="${PGDATA:-/var/lib/postgresql/data}"
export POSTGRES_USER="${POSTGRES_USER:-supabase_admin}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-postgres}"

first_boot=0
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  first_boot=1
  echo "Initializing database (portable bundle init)"
  # The init script unconditionally ends with `exec postgres -D $PGDATA
  # "$@"`. Passing `-C max_connections` turns that exec into
  # print-a-setting-and-exit, making the script a pure init step
  # (`--version` would not work: postgres only accepts it as the FIRST
  # argument; after -D it is parsed as a GUC assignment and FATALs).
  bash "$BUNDLE/share/supabase-cli/bin/supabase-postgres-init.sh" -C max_connections >/dev/null

  # The bundle's config is the docker.io recipe plus the local-dev divergence
  # file, which targets a loopback dev server (port 54322, listen 127.0.0.1)
  # for the native runtime; append only the docker overrides. Later values
  # win in postgresql.conf. Network auth (scram) and wal_level=logical come
  # from the shared recipe itself.
  {
    echo ""
    echo "# --- slim-services derived image: docker wiring ---"
    echo "listen_addresses = '*'"
    echo "port = 5432"
  } >> "$PGDATA/postgresql.conf"
fi

if [ "$first_boot" = 1 ] && [ -f "$BUNDLE/share/supabase-cli/migrations/migrate.sh" ]; then
  echo "Running supabase migrations"
  "$BUNDLE/bin/pg_ctl" -D "$PGDATA" -l "$PGDATA/migrate.log" \
    -o "-c listen_addresses='' -c port=5432" -w start \
    || { cat "$PGDATA/migrate.log" >&2; exit 1; }
  if ! ( cd "$BUNDLE/share/supabase-cli/migrations" \
      && PATH="$BUNDLE/bin:$PATH" \
        POSTGRES_HOST=/tmp \
        POSTGRES_PORT=5432 \
        POSTGRES_DB="$POSTGRES_DB" \
        POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
        sh ./migrate.sh ); then
    cat "$PGDATA/migrate.log" >&2
    "$BUNDLE/bin/pg_ctl" -D "$PGDATA" -m fast -w stop || true
    exit 1
  fi
  "$BUNDLE/bin/pg_ctl" -D "$PGDATA" -m fast -w stop
fi

if [ "$prepare_only" = 1 ]; then
  exit 0
fi

echo "Starting PostgreSQL"
# ConfigDir is /etc/postgresql (CLI `postgres -D /etc/postgresql`). Cluster
# files stay in PGDATA. Do not -D leftover PGDATA: that file is initdb
# defaults on a docker.io volume.
exec "$BUNDLE/bin/postgres" -D /etc/postgresql "$@"
