#!/bin/sh
# Derived-image entrypoint: the image is the portable artifact plus this
# wiring (HOST_NATIVE_ARTIFACTS.md, native-first convergence). The upstream
# run.sh secrets-file/startup.sh hooks are cloud-deploy conveniences and are
# intentionally absent from the local/CI image.
set -eu

export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
"$SCRIPT_DIR/bin/prepare"

echo "Starting Logflare"
exec "$SCRIPT_DIR/bin/logflare" start --sname logflare
