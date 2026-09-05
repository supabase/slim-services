#!/bin/sh
# Derived-image entrypoint: the image is the portable artifact plus this
# wiring (HOST_NATIVE_ARTIFACTS.md, native-first convergence). Cloud-deploy
# bootstrap (Fly/ECS IP discovery, cluster cert generation) from the old
# docker-source run.sh is intentionally absent from the local/CI image.
set -eu

export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

echo "Running migrations"
/app/bin/migrate

if [ "${SEED_SELF_HOST:-}" = true ]; then
  echo "Seeding selfhosted Realtime"
  /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)'
fi

echo "Starting Realtime"
exec "$@"
