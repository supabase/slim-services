#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
require_cmd curl

image="${IMAGE:-}"
artifact_rootfs="${ARTIFACT_ROOTFS:-}"

if [[ -n "$image" && -n "$artifact_rootfs" ]]; then
  fail "set only one of IMAGE or ARTIFACT_ROOTFS"
fi
if [[ -z "$image" && -z "$artifact_rootfs" ]]; then
  fail "set IMAGE to smoke a Docker image, or ARTIFACT_ROOTFS to smoke an extracted artifact"
fi

start_postgres postgrest_smoke

if [[ -n "$artifact_rootfs" ]]; then
  require_cmd python3

  cleanup_postgrest_smoke() {
    rm -f "${postgrest_log:-}"
    cleanup_smoke
  }
  trap cleanup_postgrest_smoke EXIT

  postgrest_bin="$artifact_rootfs/bin/postgrest"
  [[ -x "$postgrest_bin" ]] || fail "postgrest artifact binary not found or not executable: $postgrest_bin"

  pg_port="$(host_port "$POSTGRES_CONTAINER" 5432)"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  postgrest_log="$(mktemp "${TMPDIR:-/tmp}/postgrest-smoke.XXXXXX.log")"

  log "smoke testing postgrest host process on port $port"
  start_host_service postgrest "$postgrest_log" \
    PGRST_DB_URI="postgresql://postgres:postgres@127.0.0.1:$pg_port/postgrest_smoke" \
    PGRST_DB_ANON_ROLE=postgres \
    PGRST_DB_SCHEMAS=public \
    PGRST_SERVER_PORT="$port" \
    -- "$postgrest_bin"

  if ! wait_for_http_code_host "http://127.0.0.1:$port/" "200" 120 "$host_service_pid" "$postgrest_log"; then
    fail "postgrest root endpoint did not return 200"
  fi
  record_host_runtime_metrics "$host_service_pid"
  log "postgrest smoke passed"
  exit 0
fi

ensure_image "$image"

container="postgrest-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::3000 \
  -e PGRST_DB_URI="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/postgrest_smoke" \
  -e PGRST_DB_ANON_ROLE=postgres \
  -e PGRST_DB_SCHEMAS=public \
  -e PGRST_SERVER_PORT=3000 \
  "$image"
port="$(host_port "$container" 3000)"

log "smoke testing postgrest on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "postgrest root endpoint did not return 200"
fi
record_runtime_metrics "$container"
log "postgrest smoke passed"
