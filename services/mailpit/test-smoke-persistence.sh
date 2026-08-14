#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require_bin="${MAILPIT_BIN:-}"
[[ -x "$require_bin" ]] || {
  printf 'MAILPIT_BIN must name the normalized Mailpit executable\n' >&2
  exit 2
}

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/mailpit-persistence-test.XXXXXX")"
log_file="$test_dir/mailpit.log"
state_dir="$test_dir/state"
mkdir "$state_dir"
pid=""

cleanup() {
  set +e
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
  if [[ -d "$test_dir" ]]; then
    rm -r "$test_dir"
  fi
}
trap cleanup EXIT

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

message_id="<mailpit-persistence-${RUN_ID:-$$}@example.test>"
checker="$ROOT_DIR/services/mailpit/smoke.py"
service_env=(
  MP_UI_BIND_ADDR="127.0.0.1:$http_port"
  MP_SMTP_BIND_ADDR="127.0.0.1:$smtp_port"
  MP_POP3_BIND_ADDR="127.0.0.1:$pop3_port"
  MP_POP3_AUTH="smoke:smoke-password"
  MP_SMTP_DISABLE_RDNS=true
  MP_DATABASE="$state_dir/mailpit.db"
)

start_mailpit() {
  env "${service_env[@]}" "$require_bin" >"$log_file" 2>&1 &
  pid="$!"
}

stop_mailpit() {
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
  pid=""
}

start_mailpit
MAILPIT_SMOKE_TIMEOUT=20 python3 "$checker" \
  127.0.0.1 "$http_port" "$smtp_port" "$pop3_port" "$message_id"
stop_mailpit

for suffix in "" -wal -shm; do
  database_path="$state_dir/mailpit.db${suffix}"
  [[ -e "$database_path" ]] && rm -f "$database_path"
done

start_mailpit
if MAILPIT_SMOKE_TIMEOUT=5 MAILPIT_SMOKE_REQUIRE_EXISTING=1 python3 "$checker" \
  127.0.0.1 "$http_port" "$smtp_port" "$pop3_port" "$message_id" \
  >"$test_dir/lost-state.out" 2>&1; then
  printf 'persistence smoke unexpectedly resent after database deletion\n' >&2
  cat "$test_dir/lost-state.out" >&2
  exit 1
fi
grep -q 'message .* is missing before persistence protocol checks' "$test_dir/lost-state.out"
printf 'mailpit persistence deletion regression passed\n'
