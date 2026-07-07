#!/bin/sh
# Derived-image entrypoint: the image is the portable artifact plus this
# wiring (HOST_NATIVE_PLAN.md, native-first convergence). The upstream
# run.sh secrets-file/startup.sh hooks are cloud-deploy conveniences and are
# intentionally absent from the local/CI image.
set -eu

export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

echo "Running migrations"
/app/bin/logflare eval Logflare.Release.migrate

echo "Starting Logflare"
exec /app/bin/logflare start --sname logflare
