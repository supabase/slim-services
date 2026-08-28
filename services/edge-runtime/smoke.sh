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
  if [[ -n "${probe_dir:-}" ]]; then
    rm -rf "$probe_dir"
  fi
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

  # ${arr[@]+...} keeps the empty-array expansion safe under `set -u` on
  # bash 3.2 (macOS /bin/bash), where a plain "${arr[@]}" errors.
  # shellcheck source=scripts/identity-lib.sh
  source "$ROOT_DIR/scripts/identity-lib.sh"
  load_recipe edge-runtime
  identity_dir="$(mktemp -d "${TMPDIR:-/tmp}/edge-runtime-identity.XXXXXX")"
  if [[ "${SKIP_UPSTREAM_IDENTITY:-}" == "1" ]]; then
    fail "edge-runtime image smoke requires the digest-pinned upstream identity (unset SKIP_UPSTREAM_IDENTITY)"
  fi
  write_upstream_identity edge-runtime "$identity_dir"
  assert_slim_matches_identity "$image" "$identity_dir/identity.env"
  # shellcheck source=/dev/null
  source "$identity_dir/identity.env"
  pinned_image="$PINNED_IMAGE"

  log "checking sh + CLI applets"
  layout="$(docker run --rm ${docker_platform_args[@]+"${docker_platform_args[@]}"} \
    --entrypoint sh "$image" -c \
    'busybox stat -c "%a %u" /root; busybox test -x /usr/bin/sh && busybox test -x /usr/bin/cat && busybox test -x /usr/bin/dirname && busybox test -x /usr/bin/uname && echo ok')" \
    || fail "layout probe failed"
  expected_layout="${VOLUME_MODE} ${VOLUME_UID}"$'\nok'
  [[ "$layout" == "$expected_layout" ]] \
    || fail "expected /root ${VOLUME_MODE}:${VOLUME_UID} and sh+cat+dirname+uname; got: $layout"

  log "checking CLI-shaped sh -c heredoc as the pin start user"
  # Same shape as CLI `legacyBuildEdgeRuntimeEntrypoint`:
  # `cat <<'SENTINEL' > file && exec edge-runtime …`.
  heredoc_body="$(docker run --rm ${docker_platform_args[@]+"${docker_platform_args[@]}"} \
    --entrypoint sh "$image" -c \
    "cat <<'S' > /tmp/p && exec edge-runtime --help
hello
S
")" || fail "sh -c heredoc+exec edge-runtime failed"
  [[ "$heredoc_body" == *"Usage:"* ]] || fail "heredoc+exec edge-runtime --help: $heredoc_body"

  log "leftover volume: /root both directions"
  edge_vol="edge-runtime-leftover-$RUN_ID"
  create_volume "$edge_vol"
  bb="$(identity_busybox_bin)"
  docker run --rm ${docker_platform_args[@]+"${docker_platform_args[@]}"} \
    -v "$bb:/busybox:ro" -v "$edge_vol:/root" --entrypoint /busybox \
    "$pinned_image" sh -c 'echo leftover-from-dockerio > /root/leftover.txt' \
    || fail "upstream could not write leftover /root"
  leftover_body="$(docker run --rm ${docker_platform_args[@]+"${docker_platform_args[@]}"} \
    -v "$edge_vol:/root" --entrypoint sh "$image" \
    -c 'cat /root/leftover.txt')" \
    || fail "slim could not read docker.io leftover /root"
  [[ "$leftover_body" == "leftover-from-dockerio" ]] \
    || fail "slim leftover /root mismatch: $leftover_body"
  docker run --rm ${docker_platform_args[@]+"${docker_platform_args[@]}"} \
    -v "$edge_vol:/root" --entrypoint sh "$image" \
    -c 'echo leftover-from-slim > /root/leftover-slim.txt' \
    || fail "slim could not write leftover /root"
  leftover_body="$(docker run --rm ${docker_platform_args[@]+"${docker_platform_args[@]}"} \
    -v "$bb:/busybox:ro" -v "$edge_vol:/root" --entrypoint /busybox \
    "$pinned_image" cat /root/leftover-slim.txt)" \
    || fail "docker.io could not read slim leftover /root"
  [[ "$leftover_body" == "leftover-from-slim" ]] \
    || fail "docker.io leftover /root mismatch: $leftover_body"

  log "smoke testing edge-runtime image: --help"
  docker run --rm ${docker_platform_args[@]+"${docker_platform_args[@]}"} "$image" --help >/dev/null

  container_name="slim-smoke-edge-runtime-$RUN_ID"

  log "smoke testing edge-runtime image: local function serve"
  run_container \
    "$container_name" \
    ${docker_platform_args[@]+"${docker_platform_args[@]}"} \
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
  start_host_service edge-runtime "$edge_runtime_log" -- \
    "$edge_runtime_bin" \
    start \
    --main-service "$fixture_dir" \
    --port "$port"
  edge_runtime_pid="$host_service_pid"

  assert_smoke_body "http://127.0.0.1:$port/smoke" 90
  record_host_runtime_metrics "$edge_runtime_pid"
fi

log "edge-runtime smoke passed"
