#!/bin/sh
# Image wiring for the portable PostgreSQL service. The artifact owns
# initialization, migrations, first-boot failure handling and the final exec; this file
# only selects the image's config and optional initdb.d locations.
set -eu

export SUPABASE_POSTGRES_CONFIG_DIR="${SUPABASE_POSTGRES_CONFIG_DIR:-/etc/postgresql}"
export SUPABASE_POSTGRES_INITDB_DIR="${SUPABASE_POSTGRES_INITDB_DIR:-/docker-entrypoint-initdb.d}"
export SUPABASE_POSTGRES_SCHEMA_FILE="${SUPABASE_POSTGRES_SCHEMA_FILE:-/etc/postgresql.schema.sql}"
export SUPABASE_POSTGRES_SCHEMA_BACKUP="${SUPABASE_POSTGRES_SCHEMA_BACKUP:-/tmp/slim-schema.sql}"

exec /opt/postgres/bin/supabase-postgres-start "$@"
