#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
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
  pg_port="$(host_port "$POSTGRES_CONTAINER" 5432)"

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
  record_host_runtime_metrics "$host_service_pid"
  log "realtime smoke passed"
  exit 0
fi

ensure_image "$image"

log "checking realtime slim runtime commands"
docker run --rm --entrypoint /usr/bin/sh "$image" -c '
  set -eu
  for bin in awk base64 cat chmod curl date grep head hostname mv od openssl rm setpriv sh tini tr; do
    test -x "/usr/bin/${bin}"
  done
  /usr/bin/curl --version >/dev/null
  /usr/bin/openssl version >/dev/null
'

log "checking generated certs fail fast without AWS env"
cert_output="$(
  docker run --rm --entrypoint /usr/bin/sh \
    -e GENERATE_CLUSTER_CERTS=true \
    "$image" /app/run.sh true 2>&1 || true
)"
if ! printf '%s' "$cert_output" | grep -q 'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI is required'; then
  printf '%s\n' "$cert_output" >&2
  fail "realtime generated certs path did not fail with the expected missing-env error"
fi

log "checking AWS metadata IPv6 parser overlay"
metadata_ip="$(
  awk '
    BEGIN {
      data = "{\"Networks\":[{\"IPv6Addresses\":[\"fd00::1\",\"2600:1f18:abcd::42\"]}]}"
      if (match(data, /"IPv6Addresses"[[:space:]]*:[[:space:]]*\[/)) {
        s = substr(data, RSTART + RLENGTH)
        while (match(s, /"([^"\\]|\\.)*"/)) {
          value = substr(s, RSTART + 1, RLENGTH - 2)
          print value
          s = substr(s, RSTART + RLENGTH)
          if (match(s, /^[[:space:]]*\]/)) {
            exit
          }
        }
      }
    }
  ' | grep -Ev '^f[cd]' | head -1
)"
if [[ "$metadata_ip" != "2600:1f18:abcd::42" ]]; then
  fail "realtime AWS metadata parser did not select the public IPv6 address"
fi

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
record_runtime_metrics "$container"
log "realtime smoke passed"
