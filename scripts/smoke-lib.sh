#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

RUN_ID="${RUN_ID:-$(date +%s)-$$}"
NETWORK="${NETWORK:-slim-smoke-$RUN_ID}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-slim-smoke-postgres-$RUN_ID}"
created_containers=()
host_service_pids=()
network_created=0
host_pg_dir=""
host_pg_bin=""
host_pg_port=""

cleanup_smoke() {
  set +e
  local container pid
  for pid in "${host_service_pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
  if [[ -n "${host_pg_dir:-}" ]]; then
    "$host_pg_bin/pg_ctl" -D "$host_pg_dir/data" stop -m immediate >/dev/null 2>&1 || true
    rm -rf "$host_pg_dir"
  fi
  for container in "${created_containers[@]:-}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  if [[ "${network_created:-0}" == "1" ]]; then
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
  fi
}

trap cleanup_smoke EXIT

ensure_image() {
  local image="$1"
  docker image inspect "$image" >/dev/null 2>&1 || fail "Docker image not found locally: $image"
}

ensure_network() {
  if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create "$NETWORK" >/dev/null
    network_created=1
  fi
}

run_container() {
  local name="$1"
  shift
  docker run -d --name "$name" "$@" >/dev/null
  created_containers+=("$name")
}

container_logs() {
  local container="$1"
  printf '\n[slim-smoke] logs for %s\n' "$container" >&2
  docker logs "$container" >&2 || true
}

host_port() {
  local container="$1"
  local internal_port="$2"
  docker inspect -f "{{(index (index .NetworkSettings.Ports \"${internal_port}/tcp\") 0).HostPort}}" "$container"
}

wait_for_postgres() {
  local timeout="${1:-90}"
  local container="${2:-$POSTGRES_CONTAINER}"
  local user="${3:-postgres}"
  local start
  start="$(date +%s)"
  while true; do
    if docker exec "$container" pg_isready -h 127.0.0.1 -U "$user" >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || printf false)" != "true" ]]; then
      container_logs "$container"
      return 1
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      container_logs "$container"
      return 1
    fi
    sleep 1
  done
}

# Run psql against the harness postgres in either mode (docker container or
# host process). Usage: harness_psql DB [psql args...]; SQL via -c or stdin.
harness_psql() {
  local db="$1"
  shift
  if [[ -n "${host_pg_bin:-}" ]]; then
    "$host_pg_bin/psql" -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$host_pg_port" -U postgres -d "$db" "$@"
  else
    docker exec -i "$POSTGRES_CONTAINER" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d "$db" "$@"
  fi
}

# Host-reachable TCP port of the harness postgres, for host-process smokes.
postgres_port() {
  if [[ -n "${host_pg_port:-}" ]]; then
    printf '%s' "$host_pg_port"
  else
    host_port "$POSTGRES_CONTAINER" 5432
  fi
}

# Docker-free harness postgres for hosts without Docker (macOS CI runners):
# initdb + pg_ctl from the pinned nixpkgs, trust auth on 127.0.0.1.
start_host_postgres() {
  [[ -n "$host_pg_dir" ]] && return 0
  require_cmd python3
  # shellcheck source=scripts/nixpkgs-pin.sh
  source "$ROOT_DIR/scripts/nixpkgs-pin.sh"

  log "starting harness postgres as a host process (SLIM_SMOKE_HOST_POSTGRES=1)"
  local pg_store
  pg_store="$(nixpkgs_build_attr postgresql_16)"
  host_pg_bin="$pg_store/bin"
  host_pg_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-smoke-pg.XXXXXX")"
  host_pg_port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

  "$host_pg_bin/initdb" -D "$host_pg_dir/data" -U postgres --auth=trust >/dev/null
  "$host_pg_bin/pg_ctl" -D "$host_pg_dir/data" -l "$host_pg_dir/postgres.log" \
    -o "-p $host_pg_port -c listen_addresses=127.0.0.1 -k $host_pg_dir" \
    start >/dev/null

  local start
  start="$(date +%s)"
  while ! "$host_pg_bin/pg_isready" -h 127.0.0.1 -p "$host_pg_port" -U postgres >/dev/null 2>&1; do
    if (( "$(date +%s)" - start >= 60 )); then
      cat "$host_pg_dir/postgres.log" >&2 || true
      fail "host harness postgres did not become ready"
    fi
    sleep 1
  done
}

start_postgres() {
  local db="${1:-postgres}"

  if [[ "${SLIM_SMOKE_HOST_POSTGRES:-0}" == "1" ]]; then
    start_host_postgres
  elif ! docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1; then
    ensure_network
    # 127.0.0.1:: publishes a random host port so host-process smokes can
    # reach the harness postgres; container smokes keep using the network.
    run_container \
      "$POSTGRES_CONTAINER" \
      --network "$NETWORK" \
      -p 127.0.0.1::5432 \
      -e POSTGRES_USER=postgres \
      -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_DB=postgres \
      postgres:16-alpine
    wait_for_postgres 90
  fi

  harness_psql postgres >/dev/null <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator NOINHERIT LOGIN;
  END IF;
END
$$;
GRANT anon TO authenticator;
GRANT authenticated TO authenticator;
GRANT service_role TO authenticator;
GRANT postgres TO authenticator;
SQL

  if ! harness_psql postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
    harness_psql postgres -c "CREATE DATABASE ${db}" >/dev/null
  fi
}

wait_for_http_code() {
  local url="$1"
  local expected="$2"
  local timeout="${3:-90}"
  local auth_token="${4:-}"
  local container_name="${5:-}"
  local start http_code
  start="$(date +%s)"
  while true; do
    if [[ -n "$container_name" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || printf false)" != "true" ]]; then
      return 1
    fi
    if [[ -n "$auth_token" ]]; then
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${auth_token}" "$url" || true)"
    else
      http_code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
    fi
    [[ "$http_code" == "$expected" ]] && return 0
    if (( "$(date +%s)" - start >= timeout )); then
      return 1
    fi
    sleep 2
  done
}

# Sample steady-state RSS and CPU of a running smoke container via docker stats.
# Best effort: logs the values, and writes JSON to $SLIM_RUNTIME_METRICS_FILE when
# set (used by ci-build-service.sh to merge runtime metrics into manifest.json).
record_runtime_metrics() {
  local container="$1"
  local settle="${SLIM_RUNTIME_SETTLE:-10}"
  local samples="${SLIM_RUNTIME_SAMPLES:-3}"
  local interval="${SLIM_RUNTIME_SAMPLE_INTERVAL:-2}"

  log "sampling runtime metrics for $container (settle ${settle}s, ${samples} samples)"
  sleep "$settle"

  local metrics_json
  if ! metrics_json="$(python3 - "$container" "$samples" "$interval" "$settle" <<'PY'
import json
import subprocess
import sys
import time

container, samples, interval = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
settle = int(sys.argv[4])

UNITS = {
    "B": 1, "KB": 1000, "MB": 1000**2, "GB": 1000**3,
    "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3,
}

def parse_size(text):
    text = text.strip()
    num = ""
    for ch in text:
        if ch.isdigit() or ch == ".":
            num += ch
        else:
            break
    unit = text[len(num):].strip().upper()
    return float(num) * UNITS.get(unit, 1)

rss, cpu = [], []
for i in range(samples):
    out = subprocess.check_output(
        ["docker", "stats", "--no-stream", "--format",
         "{{.MemUsage}}|{{.CPUPerc}}", container],
        text=True, timeout=60,
    ).strip()
    mem_raw, cpu_raw = out.split("|", 1)
    try:
        rss.append(parse_size(mem_raw.split("/")[0]))
        cpu.append(float(cpu_raw.strip().rstrip("%")))
    except ValueError:
        pass
    if i < samples - 1:
        time.sleep(interval)

if not rss:
    sys.exit(1)

avg_rss = sum(rss) / len(rss)
avg_cpu = sum(cpu) / len(cpu) if cpu else None
print(json.dumps({
    "runtime_rss_bytes": int(avg_rss),
    "runtime_rss_mib": round(avg_rss / 1024 / 1024, 1),
    "idle_cpu_pct": round(avg_cpu, 2) if avg_cpu is not None else None,
    "settle_seconds": settle,
    "samples": len(rss),
}))
PY
)"; then
    log "WARNING: runtime metrics sampling failed for $container"
    return 0
  fi

  log "runtime metrics: $metrics_json"
  if [[ -n "${SLIM_RUNTIME_METRICS_FILE:-}" ]]; then
    printf '%s\n' "$metrics_json" > "$SLIM_RUNTIME_METRICS_FILE"
  fi
}

# Host-process smoke helpers: the darwin (no-Docker) counterpart of the
# container helpers above. The CLI runs these artifacts as plain processes with
# services/<service>/runtime.env applied, so the smoke must do the same.

# Print KEY=VALUE pairs from services/<service>/runtime.env (comments/blank
# lines skipped). Missing file is fine: not every service has a profile.
runtime_env_pairs() {
  local service="$1"
  local env_file="$ROOT_DIR/services/$service/runtime.env"
  [[ -f "$env_file" ]] || return 0
  grep -Ev '^[[:space:]]*(#|$)' "$env_file"
}

# Start a service as a host process with runtime.env applied.
# Usage: start_host_service SERVICE LOGFILE [EXTRA_ENV=value ...] -- CMD [ARGS...]
# Sets $host_service_pid; the process is killed by cleanup_smoke.
start_host_service() {
  local service="$1"
  local logfile="$2"
  shift 2
  local extra_env=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    extra_env+=("$1")
    shift
  done
  [[ "${1:-}" == "--" ]] || fail "start_host_service: missing -- separator before command"
  shift
  [[ $# -gt 0 ]] || fail "start_host_service: missing command"

  local runtime_env=()
  while IFS= read -r pair; do
    runtime_env+=("$pair")
  done < <(runtime_env_pairs "$service")

  env \
    ${runtime_env[@]+"${runtime_env[@]}"} \
    ${extra_env[@]+"${extra_env[@]}"} \
    "$@" >"$logfile" 2>&1 &
  host_service_pid="$!"
  host_service_pids+=("$host_service_pid")
}

# wait_for_http_code for a host process: fails fast (with logs) when the
# process exits before serving.
wait_for_http_code_host() {
  local url="$1"
  local expected="$2"
  local timeout="${3:-90}"
  local pid="$4"
  local logfile="${5:-}"
  local auth_token="${6:-}"
  local curl_args=()
  if [[ -n "$auth_token" ]]; then
    curl_args=(-H "Authorization: Bearer ${auth_token}")
  fi
  local start http_code
  start="$(date +%s)"
  while true; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      if [[ -n "$logfile" ]]; then
        printf '\n[slim-smoke] host process logs (%s)\n' "$logfile" >&2
        cat "$logfile" >&2 || true
      fi
      return 1
    fi
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' ${curl_args[@]+"${curl_args[@]}"} "$url" 2>/dev/null || true)"
    [[ "$http_code" == "$expected" ]] && return 0
    if (( "$(date +%s)" - start >= timeout )); then
      if [[ -n "$logfile" ]]; then
        printf '\n[slim-smoke] host process logs (%s)\n' "$logfile" >&2
        cat "$logfile" >&2 || true
      fi
      return 1
    fi
    sleep 2
  done
}

# Sample steady-state RSS and CPU of a host process tree via ps (docker stats
# is unavailable for host processes). Sums the process and its descendants so
# wrapper scripts and BEAM/Node children are counted. Writes the same JSON
# shape as record_runtime_metrics to $SLIM_RUNTIME_METRICS_FILE when set.
record_host_runtime_metrics() {
  local pid="$1"
  local settle="${SLIM_RUNTIME_SETTLE:-10}"
  local samples="${SLIM_RUNTIME_SAMPLES:-3}"
  local interval="${SLIM_RUNTIME_SAMPLE_INTERVAL:-2}"

  log "sampling host runtime metrics for pid $pid (settle ${settle}s, ${samples} samples)"
  sleep "$settle"

  local metrics_json
  if ! metrics_json="$(python3 - "$pid" "$samples" "$interval" "$settle" <<'PY'
import json
import subprocess
import sys
import time

root_pid, samples, interval = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
settle = int(sys.argv[4])


def sample_tree(pid):
    out = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,rss=,%cpu="], text=True, timeout=60
    )
    procs = {}
    children = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        try:
            p, pp, rss_kib, cpu_pct = int(parts[0]), int(parts[1]), int(parts[2]), float(parts[3])
        except ValueError:
            continue
        procs[p] = (rss_kib, cpu_pct)
        children.setdefault(pp, []).append(p)

    if pid not in procs:
        return None

    total_rss_kib = 0
    total_cpu = 0.0
    stack = [pid]
    while stack:
        cur = stack.pop()
        rss_kib, cpu_pct = procs[cur]
        total_rss_kib += rss_kib
        total_cpu += cpu_pct
        stack.extend(children.get(cur, []))
    return total_rss_kib * 1024, total_cpu


rss, cpu = [], []
for i in range(samples):
    result = sample_tree(root_pid)
    if result is not None:
        rss.append(result[0])
        cpu.append(result[1])
    if i < samples - 1:
        time.sleep(interval)

if not rss:
    sys.exit(1)

avg_rss = sum(rss) / len(rss)
avg_cpu = sum(cpu) / len(cpu) if cpu else None
print(json.dumps({
    "runtime_rss_bytes": int(avg_rss),
    "runtime_rss_mib": round(avg_rss / 1024 / 1024, 1),
    "idle_cpu_pct": round(avg_cpu, 2) if avg_cpu is not None else None,
    "settle_seconds": settle,
    "samples": len(rss),
}))
PY
)"; then
    log "WARNING: host runtime metrics sampling failed for pid $pid"
    return 0
  fi

  log "runtime metrics: $metrics_json"
  if [[ -n "${SLIM_RUNTIME_METRICS_FILE:-}" ]]; then
    printf '%s\n' "$metrics_json" > "$SLIM_RUNTIME_METRICS_FILE"
  fi
}

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

make_jwt() {
  local secret="$1"
  local payload="$2"
  local header='{"alg":"HS256","typ":"JWT"}'
  local header_b64 payload_b64 signature
  header_b64="$(printf '%s' "$header" | b64url)"
  payload_b64="$(printf '%s' "$payload" | b64url)"
  signature="$(
    printf '%s' "${header_b64}.${payload_b64}" \
      | openssl dgst -binary -sha256 -hmac "$secret" \
      | b64url
  )"
  printf '%s.%s.%s' "$header_b64" "$payload_b64" "$signature"
}

make_role_jwt() {
  local secret="$1"
  local role="$2"
  local now exp payload
  now="$(date +%s)"
  exp="$((now + 3600))"
  payload="$(printf '{"role":"%s","iat":%s,"exp":%s}' "$role" "$now" "$exp")"
  make_jwt "$secret" "$payload"
}
