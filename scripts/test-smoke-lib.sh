#!/usr/bin/env bash
# Host-only checks for reserve_port in scripts/smoke-lib.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
export ROOT_DIR

run_case() {
  TMPDIR="$work_dir" bash -c "set -euo pipefail; source '$ROOT_DIR/scripts/smoke-lib.sh'; $1"
}

expect_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 10000 && $1 <= 32767 )) || {
    echo "expected a non-ephemeral port, got '$1'" >&2
    exit 1
  }
}

# Callers name their variable `port` and others; each must receive the value.
for name in port var host_port http_port; do
  value="$(run_case "reserve_port $name; printf '%s' \"\$$name\"")"
  expect_port "$value"
done

# Ports stay locked until cleanup_smoke, so a second smoke cannot reuse them.
locks="$(run_case 'reserve_port a; reserve_port b; [[ $a != "$b" ]]; ls "$smoke_port_lock_dir" | sort | tr "\n" " "')"
[[ "$(wc -w <<<"$locks")" -eq 2 ]] || { echo "expected 2 locks, got: $locks" >&2; exit 1; }
rm -rf "$work_dir/slim-smoke-ports"

run_case 'reserve_port port; cleanup_smoke; [[ -z "$(ls "$smoke_port_lock_dir")" ]]'

# A port held by a listener is never handed out.
python3 - "$work_dir" <<'PY'
import os, socket, subprocess, sys
work = sys.argv[1]
root = os.environ["ROOT_DIR"]
held = []
for p in range(10000, 32768, 7):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); s.listen()
        held.append((p, s))
    except OSError:
        s.close()
    if len(held) == 200:
        break
ports = set()
for _ in range(50):
    out = subprocess.run(
        ["bash", "-c", f"set -euo pipefail; source {root}/scripts/smoke-lib.sh; reserve_port port; printf %s \"$port\""],
        env={**os.environ, "TMPDIR": work}, check=True, capture_output=True, text=True,
    ).stdout
    ports.add(int(out))
clash = ports & {p for p, _ in held}
assert not clash, f"reserved ports held by a listener: {clash}"
PY

echo "smoke-lib reserve_port tests passed"
