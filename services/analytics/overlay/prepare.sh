#!/bin/sh
# Run the service-owned database preparation before starting Logflare.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

echo "Running Analytics migrations"
"$SCRIPT_DIR/logflare" eval 'Logflare.Release.migrate'
