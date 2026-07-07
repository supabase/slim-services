#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

RUN_ID="${RUN_ID:-$(date +%s)-$$}"
NETWORK="${NETWORK:-slim-smoke-$RUN_ID}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-slim-smoke-postgres-$RUN_ID}"
created_containers=()
network_created=0

cleanup_smoke() {
  set +e
  local container
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
  local start
  start="$(date +%s)"
  while true; do
    if docker exec "$POSTGRES_CONTAINER" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
      return 0
    fi
    if (( "$(date +%s)" - start >= timeout )); then
      container_logs "$POSTGRES_CONTAINER"
      return 1
    fi
    sleep 1
  done
}

start_postgres() {
  local db="${1:-postgres}"
  ensure_network
  if ! docker inspect "$POSTGRES_CONTAINER" >/dev/null 2>&1; then
    run_container \
      "$POSTGRES_CONTAINER" \
      --network "$NETWORK" \
      -e POSTGRES_USER=postgres \
      -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_DB=postgres \
      postgres:16-alpine
    wait_for_postgres 90
  fi

  docker exec "$POSTGRES_CONTAINER" sh -lc "psql -h 127.0.0.1 -U postgres <<'SQL'
DO \$\$
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
\$\$;
GRANT anon TO authenticator;
GRANT authenticated TO authenticator;
GRANT service_role TO authenticator;
GRANT postgres TO authenticator;
SQL" >/dev/null

  docker exec "$POSTGRES_CONTAINER" sh -lc \
    "psql -h 127.0.0.1 -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='${db}'\" | grep -q 1 || createdb -h 127.0.0.1 -U postgres ${db}" \
    >/dev/null
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
