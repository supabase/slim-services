#!/bin/sh
# Derived-image entrypoint: the image is the portable postgres artifact
# (/opt/postgres) plus this wiring (HOST_NATIVE_PLAN.md, native-first — no
# exceptions). First boot delegates initialization to the bundle's own
# supabase-postgres-init.sh (initdb, CLI config templates with the pgsodium
# getkey script wired, superuser password, bundled init scripts), then this
# script applies the docker-shaped settings, runs the supabase migrations,
# and starts the server.
set -eu

BUNDLE=/opt/postgres
export PGDATA="${PGDATA:-/var/lib/postgresql/data}"
export POSTGRES_USER="${POSTGRES_USER:-supabase_admin}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
export POSTGRES_DB="${POSTGRES_DB:-postgres}"

first_boot=0
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  first_boot=1
  echo "Initializing database (portable bundle init)"
  # The init script ends with `exec postgres -D $PGDATA "$@"`; passing
  # --version makes that final exec print-and-exit instead of serving, so it
  # acts as a pure init step.
  bash "$BUNDLE/share/supabase-cli/bin/supabase-postgres-init.sh" --version >/dev/null

  # The CLI config template targets a loopback dev server (port 54322,
  # listen 127.0.0.1, wal_level=replica); append the docker/network settings
  # and the low-footprint local-dev profile. Later values win in
  # postgresql.conf.
  {
    echo ""
    echo "# --- slim-services derived image: docker wiring ---"
    echo "listen_addresses = '*'"
    echo "port = 5432"
    echo "wal_level = logical"
    echo ""
    echo "# --- slim-services low-footprint local-dev profile ---"
    cat /usr/local/share/postgres/99-local-dev.conf
  } >> "$PGDATA/postgresql.conf"
  # The template only allows loopback; containers connect over the network.
  echo "host all all all scram-sha-256" >> "$PGDATA/pg_hba.conf"
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

echo "Starting PostgreSQL"
exec "$BUNDLE/bin/postgres" -D "$PGDATA" "$@"
