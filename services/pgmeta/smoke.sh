#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd curl

image="${IMAGE:-}"
artifact_rootfs="${ARTIFACT_ROOTFS:-}"

if [[ -n "$image" && -n "$artifact_rootfs" ]]; then
  fail "set only one of IMAGE or ARTIFACT_ROOTFS"
fi
if [[ -z "$image" && -z "$artifact_rootfs" ]]; then
  fail "set IMAGE to smoke a Docker image, or ARTIFACT_ROOTFS to smoke an extracted artifact"
fi
if [[ -n "$image" || "${SLIM_SMOKE_HOST_POSTGRES:-0}" != "1" ]]; then
  require_cmd docker
fi

start_postgres pgmeta_smoke

if [[ -n "$artifact_rootfs" ]]; then
  # Host-process smoke. The artifact bundles its Node runtime; the wrapper
  # must find it with no help — SUPABASE_NODE stays unset and PATH is
  # sanitized so a host node cannot mask a broken bundle.
  require_cmd python3

  cleanup_pgmeta_smoke() {
    rm -f "${pgmeta_log:-}"
    cleanup_smoke
  }
  trap cleanup_pgmeta_smoke EXIT

  pgmeta_bin="$artifact_rootfs/bin/pgmeta"
  [[ -x "$pgmeta_bin" ]] || fail "pgmeta artifact launcher not found or not executable: $pgmeta_bin"

  [[ -x "$artifact_rootfs/node/bin/node" ]] \
    || fail "pgmeta artifact does not bundle a node runtime: $artifact_rootfs/node/bin/node"

  pg_port="$(postgres_port)"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  pgmeta_log="$(mktemp "${TMPDIR:-/tmp}/pgmeta-smoke.XXXXXX.log")"

  log "smoke testing pgmeta host process on port $port"
  start_host_service pgmeta "$pgmeta_log" \
    SUPABASE_NODE= \
    PATH=/usr/bin:/bin \
    PG_META_PORT="$port" \
    PG_META_HOST=127.0.0.1 \
    PG_META_DB_HOST=127.0.0.1 \
    PG_META_DB_PORT="$pg_port" \
    PG_META_DB_NAME=pgmeta_smoke \
    PG_META_DB_USER=postgres \
    PG_META_DB_PASSWORD=postgres \
    -- "$pgmeta_bin"

  if ! wait_for_http_code_host "http://127.0.0.1:$port/health" "200" 120 "$host_service_pid" "$pgmeta_log"; then
    fail "pgmeta /health did not return 200"
  fi
  record_host_runtime_metrics "$host_service_pid"
  log "pgmeta smoke passed"
  exit 0
fi

ensure_image "$image"

container="pgmeta-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::8080 \
  -e PG_META_PORT=8080 \
  -e PG_META_DB_HOST="$POSTGRES_CONTAINER" \
  -e PG_META_DB_PORT=5432 \
  -e PG_META_DB_NAME=pgmeta_smoke \
  -e PG_META_DB_USER=postgres \
  -e PG_META_DB_PASSWORD=postgres \
  "$image"
port="$(host_port "$container" 8080)"

log "smoke testing pgmeta on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/health" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "pgmeta /health did not return 200"
fi
record_runtime_metrics "$container"
log "pgmeta smoke passed"
