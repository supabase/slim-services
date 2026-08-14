#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd python3
image="${IMAGE:-}"
artifact_rootfs="${ARTIFACT_ROOTFS:-}"
[[ -n "$image" || -n "$artifact_rootfs" ]] || fail "set IMAGE or ARTIFACT_ROOTFS"
[[ -z "$image" || -z "$artifact_rootfs" ]] || fail "set only one of IMAGE or ARTIFACT_ROOTFS"
[[ -z "$image" ]] || { require_cmd docker; ensure_image "$image"; }

checker="$ROOT_DIR/services/imgproxy/smoke.py"
smoke_log="$(mktemp "${TMPDIR:-/tmp}/imgproxy-smoke.XXXXXX.log")"
container=""
port=""

free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

port_released() {
  python3 - "$1" <<'PY'
import socket, sys
with socket.socket() as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", int(sys.argv[1])))
PY
}

stop_host() {
  if [[ -n "${host_service_pid:-}" ]] && kill -0 "$host_service_pid" >/dev/null 2>&1; then
    kill "$host_service_pid" >/dev/null 2>&1 || true
    wait "$host_service_pid" >/dev/null 2>&1 || true
  fi
  host_service_pid=""
}

run_checker() {
  local endpoint="$1"
  local mode_arg=()
  if [[ -n "$artifact_rootfs" ]]; then
    mode_arg=(--rootfs "$artifact_rootfs")
  else
    mode_arg=(--image "$image")
  fi
  IMGPROXY_SMOKE_ENDPOINT="$endpoint" python3 "$checker" "${mode_arg[@]}"
}

trap 'set +e; cleanup_smoke; rm -f "$smoke_log"' EXIT

if [[ -n "$artifact_rootfs" ]]; then
  [[ -x "$artifact_rootfs/bin/imgproxy" ]] || fail "imgproxy artifact binary not found: $artifact_rootfs/bin/imgproxy"
  port="$(free_port)"
  host_env=(IMGPROXY_BIND="127.0.0.1:$port" IMGPROXY_ALLOW_ORIGIN="*")
  start_host_service imgproxy "$smoke_log" "${host_env[@]}" -- "$artifact_rootfs/bin/imgproxy"
  wait_for_http_code_host "http://127.0.0.1:$port/health" 200 30 "$host_service_pid" "$smoke_log" || fail "imgproxy artifact did not become healthy"
  run_checker "http://127.0.0.1:$port"

  stop_host
  port_released "$port" || fail "imgproxy artifact did not release port $port"
  start_host_service imgproxy "$smoke_log" "${host_env[@]}" -- "$artifact_rootfs/bin/imgproxy"
  wait_for_http_code_host "http://127.0.0.1:$port/health" 200 30 "$host_service_pid" "$smoke_log" || fail "imgproxy artifact failed to rebind port"
  run_checker "http://127.0.0.1:$port"
  [[ -n "${IMGPROXY_SKIP_RUNTIME_SAMPLE:-}" ]] || record_host_runtime_metrics "$host_service_pid"
else
  container="imgproxy-smoke-$RUN_ID"
  run_container "$container" --add-host host.docker.internal:host-gateway -p 127.0.0.1::8080 \
    -e IMGPROXY_BIND=0.0.0.0:8080 "$image"
  port="$(host_port "$container" 8080)"
  wait_for_http_code "http://127.0.0.1:$port/health" 200 30 "" "$container" || fail "imgproxy image did not become healthy"
  run_checker "http://127.0.0.1:$port"

  docker stop "$container" >/dev/null || { container_logs "$container"; fail "imgproxy image did not stop"; }
  port_released "$port" || fail "imgproxy image did not release port $port after stop"
  docker start "$container" >/dev/null || { container_logs "$container"; fail "imgproxy image failed to restart"; }
  port="$(host_port "$container" 8080)"
  wait_for_http_code "http://127.0.0.1:$port/health" 200 30 "" "$container" || fail "imgproxy image failed to rebind port"
  run_checker "http://127.0.0.1:$port"
  [[ -n "${IMGPROXY_SKIP_RUNTIME_SAMPLE:-}" ]] || record_runtime_metrics "$container"
fi

log "imgproxy codec/restart smoke passed"
