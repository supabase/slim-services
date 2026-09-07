#!/bin/sh
# Run Storage's bundled migration entrypoint from the portable artifact layout.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
APP_DIR="$SCRIPT_DIR/../app"
NODE_BIN="${SUPABASE_NODE:-$SCRIPT_DIR/../node/bin/node}"

cd "$APP_DIR"
exec "$NODE_BIN" dist/scripts/migrate-call.js
