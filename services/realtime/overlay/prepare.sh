#!/bin/sh
# Run the service-owned database preparation before starting Realtime.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

echo "Running Realtime migrations"
if [ "${SEED_SELF_HOST:-}" = true ]; then
  echo "Migrating and seeding selfhosted Realtime in one BEAM"
  exec "$SCRIPT_DIR/realtime" eval 'Realtime.OneShotPrepare.run()'
fi

exec "$SCRIPT_DIR/migrate"
