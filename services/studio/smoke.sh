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

if [[ -n "$artifact_rootfs" ]]; then
  require_cmd python3
  host_service_pid=""

  cleanup_studio_smoke() {
    rm -f "${studio_log:-}"
    cleanup_smoke
  }
  trap cleanup_studio_smoke EXIT

  studio_bin="$artifact_rootfs/bin/studio"
  [[ -x "$studio_bin" ]] \
    || fail "studio artifact launcher not found or not executable: $studio_bin"
  [[ -x "$artifact_rootfs/node/bin/node" ]] \
    || fail "studio artifact does not bundle a node runtime: $artifact_rootfs/node/bin/node"

  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  studio_log="$(mktemp "${TMPDIR:-/tmp}/studio-smoke.XXXXXX.log")"

  log "smoke testing studio host process on port $port"
  start_host_service studio "$studio_log" \
    SUPABASE_NODE= \
    PATH=/usr/bin:/bin \
    HOSTNAME=127.0.0.1 \
    PORT="$port" \
    -- "$studio_bin"

  if ! wait_for_http_code_host \
    "http://127.0.0.1:$port/api/platform/profile" "200" 180 \
    "$host_service_pid" "$studio_log"; then
    fail "studio /api/platform/profile did not return 200"
  fi
  record_host_runtime_metrics "$host_service_pid"
  log "studio smoke passed"
  exit 0
fi

require_cmd docker
ensure_image "$image"
ensure_network

container="studio-smoke-$RUN_ID"
run_container "$container" --network "$NETWORK" -p 127.0.0.1::3000 "$image"
port="$(host_port "$container" 3000)"

log "smoke testing studio on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/api/platform/profile" "200" 180 "" "$container"; then
  container_logs "$container"
  fail "studio /api/platform/profile did not return 200"
fi
log "waiting for the baked HEALTHCHECK to report healthy"
if ! wait_for_container_healthy "$container" 120; then
  container_logs "$container"
  fail "studio container did not become healthy via the image HEALTHCHECK"
fi
record_runtime_metrics "$container"
log "studio smoke passed"
