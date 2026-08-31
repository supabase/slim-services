#!/bin/sh
# Derived-image entrypoint: the image is the portable artifact plus this
# wiring (HOST_NATIVE_PLAN.md, native-first convergence). The upstream
# run.sh secrets-file/startup.sh hooks are cloud-deploy conveniences and are
# intentionally absent from the local/CI image.
set -eu

export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

echo "Running migrations"
/opt/app/rel/logflare/bin/logflare eval Logflare.Release.migrate

echo "Starting Logflare"
exec /opt/app/rel/logflare/bin/logflare start --sname logflare
