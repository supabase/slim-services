#!/bin/bash
# Docker COPY strips ownership when assembling the slim image, but postgres
# writes under /etc/postgresql-custom at startup (pgsodium root key) and the
# entrypoint edits /etc/postgresql. Restore ownership here (we start as root
# and docker-entrypoint.sh gosu-drops to postgres) instead of shipping
# world-writable config directories.
set -e
chown -R postgres:postgres /etc/postgresql /etc/postgresql-custom 2>/dev/null || true
exec /usr/local/bin/docker-entrypoint.sh "$@"
