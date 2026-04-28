#!/usr/bin/sh
set -eu

if [ -n "${RLIMIT_NOFILE:-}" ]; then
  echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
  ulimit -n "$RLIMIT_NOFILE"
fi

exec "$@"
