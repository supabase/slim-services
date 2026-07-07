#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd curl
require_cmd openssl

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

start_postgres pooler_smoke

api_secret='pooler-api-secret-with-at-least-32-characters'
metrics_secret='pooler-metrics-secret-with-at-least-32'
secret_key_base="$(openssl rand -hex 32)"
token="$(make_role_jwt "$api_secret" "service_role")"

if [[ -n "$artifact_rootfs" ]]; then
  # Host-process smoke: the artifact is a self-contained mix release run
  # directly on the host.
  require_cmd python3

  cleanup_pooler_smoke() {
    rm -f "${pooler_log:-}"
    cleanup_smoke
  }
  trap cleanup_pooler_smoke EXIT

  pooler_bin="$artifact_rootfs/bin/supavisor"
  [[ -x "$pooler_bin" ]] || fail "pooler artifact launcher not found or not executable: $pooler_bin"

  pg_port="$(postgres_port)"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  pooler_log="$(mktemp "${TMPDIR:-/tmp}/pooler-smoke.XXXXXX.log")"

  pooler_env=(
    DATABASE_URL="ecto://postgres:postgres@127.0.0.1:$pg_port/pooler_smoke"
    SECRET_KEY_BASE="$secret_key_base"
    API_JWT_SECRET="$api_secret"
    METRICS_JWT_SECRET="$metrics_secret"
    PORT="$port"
  )

  log "running pooler migrations"
  if ! env "${pooler_env[@]}" "$artifact_rootfs/bin/migrate" >"$pooler_log" 2>&1; then
    cat "$pooler_log" >&2
    fail "pooler migrations failed"
  fi

  log "smoke testing pooler host process on port $port"
  start_host_service pooler "$pooler_log" \
    "${pooler_env[@]}" \
    -- "$artifact_rootfs/bin/server"

  if ! wait_for_http_code_host "http://127.0.0.1:$port/api/health" "204" 180 "$host_service_pid" "$pooler_log" "$token"; then
    fail "pooler /api/health did not return 204"
  fi
  record_host_runtime_metrics "$host_service_pid"
  log "pooler smoke passed"
  exit 0
fi

ensure_image "$image"

container="pooler-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::4000 \
  -e DATABASE_URL="ecto://postgres:postgres@$POSTGRES_CONTAINER:5432/pooler_smoke" \
  -e SECRET_KEY_BASE="$secret_key_base" \
  -e API_JWT_SECRET="$api_secret" \
  -e METRICS_JWT_SECRET="$metrics_secret" \
  "$image"
port="$(host_port "$container" 4000)"

log "smoke testing pooler on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/api/health" "204" 180 "$token" "$container"; then
  container_logs "$container"
  fail "pooler /api/health did not return 204"
fi
record_runtime_metrics "$container"
log "pooler smoke passed"
