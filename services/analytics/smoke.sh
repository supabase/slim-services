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

start_postgres analytics_smoke

secret_key_base="$(openssl rand -hex 32)"
db_encryption_key="$(printf '0123456789abcdef0123456789abcdef' | openssl base64 -A)"

if [[ -n "$artifact_rootfs" ]]; then
  # Host-process smoke: the artifact is a self-contained mix release run
  # directly on the host.
  require_cmd python3

  cleanup_analytics_smoke() {
    rm -f "${analytics_log:-}"
    cleanup_smoke
  }
  trap cleanup_analytics_smoke EXIT

  logflare_bin="$artifact_rootfs/bin/logflare"
  [[ -x "$logflare_bin" ]] || fail "analytics artifact launcher not found or not executable: $logflare_bin"

  pg_port="$(postgres_port)"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  analytics_log="$(mktemp "${TMPDIR:-/tmp}/analytics-smoke.XXXXXX.log")"

  analytics_env=(
    DB_DATABASE=analytics_smoke
    DB_HOSTNAME=127.0.0.1
    DB_PORT="$pg_port"
    DB_USERNAME=postgres
    DB_PASSWORD=postgres
    LOGFLARE_SINGLE_TENANT=true
    LOGFLARE_API_KEY=smoke-api-key
    LOGFLARE_DB_ENCRYPTION_KEY="$db_encryption_key"
    PHX_HTTP_PORT="$port"
    PHX_SECRET_KEY_BASE="$secret_key_base"
  )

  log "running analytics migrations"
  if ! env "${analytics_env[@]}" "$logflare_bin" eval Logflare.Release.migrate >"$analytics_log" 2>&1; then
    cat "$analytics_log" >&2
    fail "analytics migrations failed"
  fi

  log "smoke testing analytics host process on port $port"
  start_host_service analytics "$analytics_log" \
    "${analytics_env[@]}" \
    -- "$logflare_bin" start --sname logflare

  if ! wait_for_http_code_host "http://127.0.0.1:$port/health" "200" 180 "$host_service_pid" "$analytics_log"; then
    fail "analytics /health did not return 200"
  fi
  record_host_runtime_metrics "$host_service_pid"
  log "analytics smoke passed"
  exit 0
fi

ensure_image "$image"

log "checking wget is on PATH (CLI healthcheck)"
docker run --rm --entrypoint /usr/bin/wget "$image" --help >/dev/null \
  || fail "analytics image is missing wget"

# The CLI drives this image and docker.io supabase/logflare with one spec:
# `sh -c` from the image WORKDIR, writing a run.sh there and calling
# ./logflare, with gcloud.json bound into that same cwd.
log "checking the CLI cwd contract (WORKDIR, ./logflare, writable cwd)"
workdir="$(docker image inspect --format '{{.Config.WorkingDir}}' "$image")"
[[ "$workdir" == "/opt/app/rel/logflare/bin" ]] \
  || fail "analytics WORKDIR is $workdir, expected /opt/app/rel/logflare/bin"
docker run --rm --entrypoint sh "$image" -c 'test -x ./logflare && : > run.sh' \
  || fail "analytics WORKDIR lacks an executable ./logflare or is not writable"

container="analytics-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::4000 \
  -e DB_DATABASE=analytics_smoke \
  -e DB_HOSTNAME="$POSTGRES_CONTAINER" \
  -e DB_PORT=5432 \
  -e DB_USERNAME=postgres \
  -e DB_PASSWORD=postgres \
  -e LOGFLARE_SINGLE_TENANT=true \
  -e LOGFLARE_API_KEY=smoke-api-key \
  -e LOGFLARE_DB_ENCRYPTION_KEY="$db_encryption_key" \
  -e PHX_HTTP_PORT=4000 \
  -e PHX_SECRET_KEY_BASE="$secret_key_base" \
  "$image"
port="$(host_port "$container" 4000)"

log "smoke testing analytics on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/health" "200" 180 "" "$container"; then
  container_logs "$container"
  fail "analytics /health did not return 200"
fi
log "CLI health-cmd: wget --spider /health"
if ! docker exec "$container" wget -q --spider http://127.0.0.1:4000/health; then
  container_logs "$container"
  fail "analytics wget --spider /health failed"
fi
record_runtime_metrics "$container"
log "analytics smoke passed"
