#!/bin/sh
# Run the service-owned database preparation before starting Supavisor.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

echo "Running Supavisor migrations"
"$SCRIPT_DIR/migrate"
