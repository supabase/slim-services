#!/bin/sh
# Derived-image entrypoint: the image is the portable artifact plus this
# wiring (HOST_NATIVE_PLAN.md, native-first convergence).
set -eu

if [ -n "${RLIMIT_NOFILE:-}" ]; then
  echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
  ulimit -n "$RLIMIT_NOFILE"
fi

export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

echo "Running migrations"
/app/bin/migrate

echo "Starting Supavisor"
exec "$@"
