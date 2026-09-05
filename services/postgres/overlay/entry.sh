#!/bin/sh
# Image wiring for the portable PostgreSQL service. The artifact owns
# initialization, migrations, first-boot failure handling and the final exec;
# this file only selects the image's config location.
set -eu

export SUPABASE_POSTGRES_CONFIG_DIR="${SUPABASE_POSTGRES_CONFIG_DIR:-/etc/postgresql}"

exec /opt/postgres/bin/supabase-postgres-start "$@"
