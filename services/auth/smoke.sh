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

cleanup_auth_smoke() {
  rm -f "${auth_log:-}"
  cleanup_smoke
}
trap cleanup_auth_smoke EXIT

jwt_secret='auth-jwt-secret-with-at-least-32-characters'

start_postgres auth_smoke
harness_psql auth_smoke -c 'CREATE SCHEMA IF NOT EXISTS auth' >/dev/null

if [[ -n "$image" ]]; then
  ensure_image "$image"

  auth_ep="$(docker inspect -f '{{json .Config.Entrypoint}}' "$image")"
  [[ "$auth_ep" == "null" || "$auth_ep" == "[]" ]] \
    || fail "auth ENTRYPOINT is $auth_ep (expected empty)"
  auth_cmd="$(docker inspect -f '{{json .Config.Cmd}}' "$image")"
  [[ "$auth_cmd" == '["gotrue"]' ]] \
    || fail "auth CMD is $auth_cmd (expected [gotrue])"

  log "checking sh and wget on PATH (CLI healthcheck)"
  docker run --rm --entrypoint /bin/sh "$image" -c 'command -v sh && command -v wget' >/dev/null \
    || fail "auth image is missing sh or wget"

  log "checking gotrue executable"
  docker run --rm "$image" gotrue version >/dev/null \
    || fail "gotrue version failed (empty ENTRYPOINT + gotrue symlink)"

  log "CLI one-shot: gotrue migrate"
  if ! docker run --rm --network "$NETWORK" \
    -e GOTRUE_SITE_URL=http://localhost:9999 \
    -e API_EXTERNAL_URL=http://localhost:9999 \
    -e GOTRUE_API_HOST=0.0.0.0 \
    -e GOTRUE_DB_DRIVER=postgres \
    -e GOTRUE_DB_DATABASE_URL="postgres://postgres:postgres@$POSTGRES_CONTAINER:5432/auth_smoke?sslmode=disable" \
    -e GOTRUE_JWT_SECRET="$jwt_secret" \
    -e GOTRUE_JWT_AUD=authenticated \
    -e GOTRUE_LOG_LEVEL=warn \
    "$image" \
    gotrue migrate; then
    fail "gotrue migrate one-shot failed"
  fi

  container="auth-smoke-$RUN_ID"
  # No -e PORT: the image bakes ENV PORT=9999 (gotrue's built-in default is
  # 8081) and the smoke must prove the baked port contract the HEALTHCHECK
  # relies on, not mask it with an injected override.
  run_container \
    "$container" \
    --network "$NETWORK" \
    -p 127.0.0.1::9999 \
    -e GOTRUE_SITE_URL=http://localhost:9999 \
    -e API_EXTERNAL_URL=http://localhost:9999 \
    -e GOTRUE_API_HOST=0.0.0.0 \
    -e GOTRUE_DB_DRIVER=postgres \
    -e GOTRUE_DB_DATABASE_URL="postgres://postgres:postgres@$POSTGRES_CONTAINER:5432/auth_smoke?sslmode=disable" \
    -e GOTRUE_JWT_SECRET="$jwt_secret" \
    -e GOTRUE_JWT_AUD=authenticated \
    -e GOTRUE_LOG_LEVEL=warn \
    "$image"
  port="$(host_port "$container" 9999)"

  log "smoke testing auth on port $port"
  if ! wait_for_http_code "http://127.0.0.1:$port/health" "200" 120 "" "$container"; then
    container_logs "$container"
    fail "auth /health did not return 200"
  fi
  log "CLI health-cmd: wget --no-verbose --tries=1 --spider"
  if ! docker exec "$container" wget --no-verbose --tries=1 --spider http://127.0.0.1:9999/health; then
    container_logs "$container"
    fail "auth wget health-cmd failed"
  fi
  log "waiting for the baked HEALTHCHECK to report healthy"
  if ! wait_for_container_healthy "$container" 60; then
    container_logs "$container"
    fail "auth container did not become healthy via the image HEALTHCHECK"
  fi
  record_runtime_metrics "$container"
else
  require_cmd python3

  auth_bin="$artifact_rootfs/bin/auth"
  [[ -x "$auth_bin" ]] || fail "auth artifact binary not found or not executable: $auth_bin"

  log "checking auth executable"
  "$auth_bin" version >/dev/null

  pg_port="$(postgres_port)"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  auth_log="$(mktemp "${TMPDIR:-/tmp}/auth-smoke.XXXXXX.log")"

  log "smoke testing auth host process on port $port"
  start_host_service auth "$auth_log" \
    GOTRUE_SITE_URL="http://localhost:$port" \
    API_EXTERNAL_URL="http://localhost:$port" \
    GOTRUE_API_HOST=127.0.0.1 \
    PORT="$port" \
    GOTRUE_DB_DRIVER=postgres \
    GOTRUE_DB_DATABASE_URL="postgres://postgres:postgres@127.0.0.1:$pg_port/auth_smoke?sslmode=disable" \
    GOTRUE_JWT_SECRET="$jwt_secret" \
    GOTRUE_JWT_AUD=authenticated \
    GOTRUE_LOG_LEVEL=warn \
    -- "$auth_bin"

  if ! wait_for_http_code_host "http://127.0.0.1:$port/health" "200" 120 "$host_service_pid" "$auth_log"; then
    fail "auth /health did not return 200"
  fi
  record_host_runtime_metrics "$host_service_pid"
fi

log "auth smoke passed"
