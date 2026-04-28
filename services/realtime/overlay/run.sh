#!/usr/bin/sh
set -eu

ulimit -n

if [ -n "${RLIMIT_NOFILE:-}" ]; then
  echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
  ulimit -Sn "$RLIMIT_NOFILE"
fi

export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

run_as_nobody() {
  exec /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups "$@"
}

run_step_as_nobody() {
  /usr/bin/setpriv --reuid=65534 --regid=65534 --clear-groups "$@"
}

echo "Running migrations"
run_step_as_nobody /app/bin/migrate

if [ "${SEED_SELF_HOST:-}" = true ]; then
  echo "Seeding selfhosted Realtime"
  run_step_as_nobody /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)'
fi

echo "Starting Realtime"
ulimit -n
run_as_nobody "$@"
