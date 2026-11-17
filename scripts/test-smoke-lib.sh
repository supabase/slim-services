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

# Deterministic skip coverage: hold every candidate port with a listener except
# three, lock one of those three as another smoke would, and the helper must
# hand out exactly the other two and then fail on exhaustion.
python3 - "$work_dir" <<'PY'
import os, resource, socket, subprocess, sys
work, root = sys.argv[1], os.environ["ROOT_DIR"]
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
want = 24000
if hard != resource.RLIM_INFINITY and hard < want:
    sys.exit(f"need RLIMIT_NOFILE >= {want} to hold the candidate range, hard limit is {hard}")
resource.setrlimit(resource.RLIMIT_NOFILE, (want, hard))
held, free = [], []
for port in range(10000, 32768):
    sock = socket.socket()
    try:
        sock.bind(("127.0.0.1", port))
        sock.listen()
    except OSError:
        sock.close()  # already held by something else on the host
        continue
    if len(free) < 3:
        sock.close()
        free.append(port)
    else:
        held.append(sock)
assert len(free) == 3, f"found only {len(free)} free ports"
lock_dir = os.path.join(work, "slim-smoke-ports")
os.makedirs(os.path.join(lock_dir, str(free[0])))
script = f"""set -euo pipefail
source {root}/scripts/smoke-lib.sh
reserve_port a
reserve_port b
if (reserve_port c) 2>/dev/null; then echo 'reserve_port did not fail on exhaustion' >&2; exit 1; fi
printf '%s %s' "$a" "$b"
"""
out = subprocess.run(["bash", "-c", script], env={**os.environ, "TMPDIR": work},
                     check=True, capture_output=True, text=True).stdout
got = sorted(int(p) for p in out.split())
assert got == sorted(free[1:]), f"expected {sorted(free[1:])}, got {got}"
assert os.path.isdir(os.path.join(lock_dir, str(free[0]))), "another smoke's lock was released"
PY

echo "smoke-lib reserve_port tests passed"
