#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd python3

image="${IMAGE:-}"
artifact_rootfs="${ARTIFACT_ROOTFS:-}"

if [[ -n "$image" && -n "$artifact_rootfs" ]]; then
  fail "set only one of IMAGE or ARTIFACT_ROOTFS"
fi
if [[ -z "$image" && -z "$artifact_rootfs" ]]; then
  fail "set IMAGE to smoke a Docker image, or ARTIFACT_ROOTFS to smoke an extracted artifact"
fi

if [[ -n "$image" ]]; then
  require_cmd docker
  ensure_image "$image"
fi

state_dir="$(mktemp -d "${TMPDIR:-/tmp}/mailpit-smoke-data.XXXXXX")"
smoke_log="$(mktemp "${TMPDIR:-/tmp}/mailpit-smoke.XXXXXX.log")"
container=""

cleanup_mailpit_smoke() {
  set +e
  cleanup_smoke
  if [[ -n "${smoke_log:-}" ]]; then
    rm -f "$smoke_log"
  fi
  if [[ -n "${state_dir:-}" && -d "$state_dir" ]]; then
    rm -r "$state_dir"
  fi
}
trap cleanup_mailpit_smoke EXIT

read -r http_port smtp_port pop3_port <<<"$(python3 - <<'PY'
import socket

ports = []
sockets = []
for _ in range(3):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    sockets.append(sock)
    ports.append(str(sock.getsockname()[1]))
print(" ".join(ports))
for sock in sockets:
    sock.close()
PY
)"
message_id="<mailpit-smoke-${RUN_ID}@example.test>"
smoke_checker="$ROOT_DIR/services/mailpit/smoke.py"

run_checker() {
  if ! python3 "$smoke_checker" 127.0.0.1 "$http_port" "$smtp_port" "$pop3_port" "$message_id"; then
    if [[ -n "$container" ]]; then
      container_logs "$container"
    else
      printf '\n[slim-smoke] mailpit host process logs\n' >&2
      cat "$smoke_log" >&2 || true
    fi
    fail "Mailpit protocol smoke failed"
  fi
}

stop_host_mailpit() {
  if [[ -n "${host_service_pid:-}" ]] && kill -0 "$host_service_pid" >/dev/null 2>&1; then
    kill "$host_service_pid" >/dev/null 2>&1 || true
    wait "$host_service_pid" >/dev/null 2>&1 || true
  fi
}

if [[ -n "$artifact_rootfs" ]]; then
  mailpit_bin="$artifact_rootfs/bin/mailpit"
  [[ -x "$mailpit_bin" ]] || fail "mailpit artifact binary not found or not executable: $mailpit_bin"

  host_env=(
    MP_UI_BIND_ADDR="127.0.0.1:$http_port"
    MP_SMTP_BIND_ADDR="127.0.0.1:$smtp_port"
    MP_POP3_BIND_ADDR="127.0.0.1:$pop3_port"
    MP_POP3_AUTH="smoke:smoke-password"
    MP_DATABASE="$state_dir/mailpit.db"
  )

  log "smoke testing mailpit artifact on ports $http_port/$smtp_port/$pop3_port"
  start_host_service mailpit "$smoke_log" "${host_env[@]}" -- "$mailpit_bin"
  run_checker

  log "stopping and restarting mailpit artifact against the same database"
  stop_host_mailpit
  start_host_service mailpit "$smoke_log" "${host_env[@]}" -- "$mailpit_bin"
  run_checker
  record_host_runtime_metrics "$host_service_pid"
else
  chmod 777 "$state_dir"
  container="mailpit-smoke-$RUN_ID"
  run_container \
    "$container" \
    -p 127.0.0.1::8025 \
    -p 127.0.0.1::1025 \
    -p 127.0.0.1::1110 \
    -v "$state_dir:/tmp/mailpit" \
    -e MP_UI_BIND_ADDR=0.0.0.0:8025 \
    -e MP_SMTP_BIND_ADDR=0.0.0.0:1025 \
    -e MP_POP3_BIND_ADDR=0.0.0.0:1110 \
    -e MP_POP3_AUTH=smoke:smoke-password \
    -e MP_SMTP_DISABLE_RDNS=true \
    -e MP_DATABASE=/tmp/mailpit/mailpit.db \
    "$image"
  http_port="$(host_port "$container" 8025)"
  smtp_port="$(host_port "$container" 1025)"
  pop3_port="$(host_port "$container" 1110)"

  log "smoke testing mailpit image on ports $http_port/$smtp_port/$pop3_port"
  run_checker

  log "stopping and restarting mailpit image against the same database"
  docker stop "$container" >/dev/null || { container_logs "$container"; fail "Mailpit image did not stop"; }
  docker start "$container" >/dev/null || { container_logs "$container"; fail "Mailpit image ports did not rebind"; }
  http_port="$(host_port "$container" 8025)"
  smtp_port="$(host_port "$container" 1025)"
  pop3_port="$(host_port "$container" 1110)"
  run_checker
  record_runtime_metrics "$container"
fi

log "mailpit smoke passed"
