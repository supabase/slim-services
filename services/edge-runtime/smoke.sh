#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd curl

cleanup_edge_smoke() {
  if [[ -n "${edge_runtime_pid:-}" ]] && kill -0 "$edge_runtime_pid" >/dev/null 2>&1; then
    kill "$edge_runtime_pid" >/dev/null 2>&1 || true
    wait "$edge_runtime_pid" >/dev/null 2>&1 || true
  fi
  rm -f "${edge_runtime_log:-}"
  cleanup_smoke
}
trap cleanup_edge_smoke EXIT

fixture_dir="$ROOT_DIR/services/edge-runtime/fixtures/smoke-function"
image="${IMAGE:-}"
artifact_rootfs="${ARTIFACT_ROOTFS:-}"

if [[ -n "$image" && -n "$artifact_rootfs" ]]; then
  fail "set only one of IMAGE or ARTIFACT_ROOTFS"
fi

if [[ -z "$image" && -z "$artifact_rootfs" ]]; then
  fail "set IMAGE to smoke a Docker image, or ARTIFACT_ROOTFS to smoke an extracted artifact"
fi

assert_smoke_body() {
  local url="$1"
  local timeout="${2:-90}"
  local check_container="${3:-}"
  local start_time body
  start_time="$(date +%s)"

  while true; do
    if [[ -n "$check_container" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$check_container" 2>/dev/null || printf false)" != "true" ]]; then
      container_logs "$check_container"
      fail "edge-runtime smoke container exited before serving"
    fi

    if [[ -n "${edge_runtime_pid:-}" ]] && ! kill -0 "$edge_runtime_pid" >/dev/null 2>&1; then
      printf '\n[slim-smoke] edge-runtime local artifact logs\n' >&2
      cat "$edge_runtime_log" >&2 || true
      fail "edge-runtime local artifact exited before serving"
    fi

    body="$(curl -fsS "$url" 2>/dev/null || true)"
    case "$body" in
      *'"ok":true'*'"method":"GET"'*'"path":"/smoke"'*) break ;;
    esac

    if (( "$(date +%s)" - start_time >= timeout )); then
      if [[ -n "$check_container" ]]; then
        container_logs "$check_container"
      elif [[ -n "${edge_runtime_log:-}" ]]; then
        printf '\n[slim-smoke] edge-runtime local artifact logs\n' >&2
        cat "$edge_runtime_log" >&2 || true
      fi
      fail "edge-runtime smoke endpoint did not return expected body"
    fi

    sleep 2
  done
}

if [[ -n "$image" ]]; then
  require_cmd docker
  ensure_image "$image"
  docker_platform_args=()
  if [[ -n "${PLATFORM:-}" ]]; then
    docker_platform_args=(--platform "$PLATFORM")
  fi

  log "smoke testing edge-runtime image: --help"
  docker run --rm "${docker_platform_args[@]}" "$image" --help >/dev/null

  container_name="slim-smoke-edge-runtime-$RUN_ID"

  log "smoke testing edge-runtime image: local function serve"
  run_container \
    "$container_name" \
    "${docker_platform_args[@]}" \
    -p 127.0.0.1::9000 \
    -v "$fixture_dir:/tmp/edge-smoke-function:ro" \
    "$image" \
    start \
    --main-service /tmp/edge-smoke-function \
    --port 9000

  port="$(host_port "$container_name" 9000)"
  assert_smoke_body "http://127.0.0.1:$port/smoke" 90 "$container_name"
  record_runtime_metrics "$container_name"
else
  require_cmd python3

  edge_runtime_bin="$artifact_rootfs/bin/edge-runtime"
  [[ -x "$edge_runtime_bin" ]] || fail "edge-runtime artifact binary not found or not executable: $edge_runtime_bin"

  log "smoke testing edge-runtime artifact: --help"
  "$edge_runtime_bin" --help >/dev/null

  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  edge_runtime_log="$(mktemp "${TMPDIR:-/tmp}/edge-runtime-smoke.XXXXXX.log")"

  log "smoke testing edge-runtime artifact: local function serve"
  "$edge_runtime_bin" \
    start \
    --main-service "$fixture_dir" \
    --port "$port" \
    >"$edge_runtime_log" 2>&1 &
  edge_runtime_pid="$!"

  assert_smoke_body "http://127.0.0.1:$port/smoke" 90
fi

log "edge-runtime smoke passed"
