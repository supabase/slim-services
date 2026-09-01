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

if [[ -n "$artifact_rootfs" ]]; then
  # Host-process smoke: the artifact is a self-contained mix release run
  # directly on the host (no Docker for the service; the harness postgres
  # still runs in Docker).
  require_cmd python3

  cleanup_realtime_smoke() {
    rm -f "${realtime_log:-}"
    cleanup_smoke
  }
  trap cleanup_realtime_smoke EXIT

  realtime_bin="$artifact_rootfs/bin/realtime"
  [[ -x "$realtime_bin" ]] || fail "realtime artifact launcher not found or not executable: $realtime_bin"

  start_postgres realtime_smoke
  pg_port="$(postgres_port)"

  api_secret='realtime-api-secret-with-at-least-32-characters'
  metrics_secret='realtime-metrics-secret-with-at-least-32'
  secret_key_base="$(openssl rand -hex 32)"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  realtime_log="$(mktemp "${TMPDIR:-/tmp}/realtime-smoke.XXXXXX.log")"

  rt_env=(
    DB_HOST=127.0.0.1
    DB_PORT="$pg_port"
    DB_USER=postgres
    DB_PASSWORD=postgres
    DB_NAME=realtime_smoke
    DB_ENC_KEY=0123456789abcdef
    API_JWT_SECRET="$api_secret"
    METRICS_JWT_SECRET="$metrics_secret"
    SECRET_KEY_BASE="$secret_key_base"
    APP_NAME=realtime-smoke
    PORT="$port"
    RELEASE_DISTRIBUTION=none
  )

  log "running realtime migrations"
  if ! env "${rt_env[@]}" "$artifact_rootfs/bin/migrate" >"$realtime_log" 2>&1; then
    cat "$realtime_log" >&2
    fail "realtime migrations failed"
  fi

  log "seeding selfhosted realtime"
  if ! env "${rt_env[@]}" "$realtime_bin" eval 'Realtime.Release.seeds(Realtime.Repo)' >"$realtime_log" 2>&1; then
    cat "$realtime_log" >&2
    fail "realtime seeds failed"
  fi

  log "smoke testing realtime host process on port $port"
  start_host_service realtime "$realtime_log" \
    "${rt_env[@]}" \
    -- "$artifact_rootfs/bin/server"

  if ! wait_for_http_code_host "http://127.0.0.1:$port/healthcheck" "200" 180 "$host_service_pid" "$realtime_log"; then
    fail "realtime /healthcheck did not return 200"
  fi
  if ! env "${rt_env[@]}" "$realtime_bin" eval \
    'if Code.ensure_loaded?(Lumis), do: true = Lumis.available_languages() != []' \
    >>"$realtime_log" 2>&1; then
    cat "$realtime_log" >&2
    fail "realtime Lumis native smoke failed"
  fi
  record_host_runtime_metrics "$host_service_pid"
  log "realtime smoke passed"
  exit 0
fi

ensure_image "$image"

# Derived image: portable artifact + busybox/tini entry wiring. The full
# functional proof is the container boot below (entry.sh runs migrations and
# seeds before serving).
log "checking realtime derived-image entry wiring"
docker run --rm --entrypoint /usr/bin/sh "$image" -c '
  set -eu
  for bin in sh tini wget; do
    test -x "/usr/bin/${bin}"
  done
  test -x /app/bin/realtime
  test -x /app/bin/server
  test -x /app/bin/migrate
  test -r /app/entry.sh
'

start_postgres realtime_smoke

api_secret='realtime-api-secret-with-at-least-32-characters'
metrics_secret='realtime-metrics-secret-with-at-least-32'
secret_key_base="$(openssl rand -hex 32)"

container="realtime-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::4000 \
  -e DB_HOST="$POSTGRES_CONTAINER" \
  -e DB_PORT=5432 \
  -e DB_USER=postgres \
  -e DB_PASSWORD=postgres \
  -e DB_NAME=realtime_smoke \
  -e DB_ENC_KEY=0123456789abcdef \
  -e API_JWT_SECRET="$api_secret" \
  -e METRICS_JWT_SECRET="$metrics_secret" \
  -e SECRET_KEY_BASE="$secret_key_base" \
  -e APP_NAME=realtime-smoke \
  -e SEED_SELF_HOST=true \
  "$image"
port="$(host_port "$container" 4000)"

log "smoke testing realtime on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/healthcheck" "200" 180 "" "$container"; then
  container_logs "$container"
  fail "realtime /healthcheck did not return 200"
fi
# CLI probes 127.0.0.1:4000 /api/ping with Host: TenantId (realtime-dev).
# Host-mapped /healthcheck can succeed before loopback accepts.
log "CLI health-cmd: wget --spider /api/ping"
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if docker exec "$container" wget -q --spider http://127.0.0.1:4000/healthcheck; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || {
  container_logs "$container"
  fail "realtime loopback /healthcheck never accepted"
}
if ! docker exec "$container" wget -q --spider --header=Host:realtime-dev http://127.0.0.1:4000/api/ping; then
  container_logs "$container"
  fail "realtime wget --spider /api/ping failed"
fi
if ! docker exec "$container" /app/bin/realtime eval \
  'if Code.ensure_loaded?(Lumis), do: true = Lumis.available_languages() != []'; then
  container_logs "$container"
  fail "realtime Lumis native smoke failed"
fi
record_runtime_metrics "$container"
log "realtime smoke passed"
