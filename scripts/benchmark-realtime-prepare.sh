#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

BASE_ROOTFS="$1"
CHANGED_ROOTFS="$2"
BASE_IMAGE="$3"
CHANGED_IMAGE="$4"
SAMPLES="${SAMPLES:-5}"
OUTPUT="${OUTPUT:-$ROOT_DIR/realtime-prepare-benchmark.json}"

[[ "$SAMPLES" -ge 3 ]] || fail "SAMPLES must be at least 3"
require_cmd python3
require_cmd openssl
require_cmd curl

POSTGRES_IMAGE='ghcr.io/supabase/cli/postgres:17.6.1.173@sha256:9d6e542382946cad5eb1f11f1c8108a51297902ee42fe5098358816d3784ba5a'
ensure_network
run_container "$POSTGRES_CONTAINER" --network "$NETWORK" -p 127.0.0.1::5432 \
  -e POSTGRES_PASSWORD=postgres "$POSTGRES_IMAGE"
wait_for_postgres 240 "$POSTGRES_CONTAINER" supabase_admin
sleep 5
wait_for_postgres 60 "$POSTGRES_CONTAINER" supabase_admin
postgres_port() { host_port "$POSTGRES_CONTAINER" 5432; }
harness_psql() {
  local db="$1"
  shift
  docker exec -i -e PGPASSWORD=postgres "$POSTGRES_CONTAINER" \
    psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U supabase_admin -d "$db" "$@"
}
pg_port="$(postgres_port)"
api_secret='realtime-api-secret-with-at-least-32-characters'
metrics_secret='realtime-metrics-secret-with-at-least-32'
secret_key_base="$(openssl rand -hex 32)"
results_file="$(mktemp)"
benchmark_complete=0
cleanup_benchmark() {
  if [[ "$benchmark_complete" == 0 && -f "$results_file" ]]; then
    cp "$results_file" "$OUTPUT.partial"
  else
    rm -f "$results_file"
  fi
  cleanup_smoke
}
trap cleanup_benchmark EXIT

measure_native() {
  local variant="$1" rootfs="$2" trial="$3"
  local db="rt_${variant}_${trial}"
  harness_psql postgres -c "CREATE DATABASE $db" >/dev/null
  harness_psql "$db" -c 'CREATE SCHEMA IF NOT EXISTS _realtime' >/dev/null
  local rt_env=()
  while IFS= read -r pair; do rt_env+=("$pair"); done < <(runtime_env_pairs realtime)
  rt_env+=(DB_HOST=127.0.0.1 DB_PORT="$pg_port" DB_USER=supabase_admin DB_PASSWORD=postgres
    DB_NAME="$db" DB_ENC_KEY=0123456789abcdef DB_AFTER_CONNECT_QUERY='SET search_path TO _realtime'
    API_JWT_SECRET="$api_secret" METRICS_JWT_SECRET="$metrics_secret"
    SECRET_KEY_BASE="$secret_key_base" APP_NAME=benchmark PORT=4000)
  local prepare_command=("$rootfs/bin/prepare")
  [[ "$variant" == baseline ]] && prepare_command=("$rootfs/bin/realtime" eval 'Realtime.Release.migrate(); Realtime.Release.seeds(Realtime.Repo)')
  local started finished prep_ms
  started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  env "${rt_env[@]}" SEED_SELF_HOST=true "${prepare_command[@]}" >"$RUNNER_TEMP/${variant}-${trial}-prepare.log" 2>&1 || {
    cat "$RUNNER_TEMP/${variant}-${trial}-prepare.log" >&2
    fail "$variant prepare failed on trial $trial"
  }
  finished="$(python3 -c 'import time; print(time.monotonic_ns())')"
  prep_ms="$(( (finished - started) / 1000000 ))"

  local before_metadata before_tenant before_ledger before_partitions
  before_metadata="$(harness_psql "$db" -tAc 'SELECT count(*) FROM _realtime.schema_migrations')"
  before_tenant="$(harness_psql "$db" -tAc "SELECT COALESCE((SELECT migrations_ran FROM _realtime.tenants WHERE external_id = 'realtime-dev'), -1)")"
  before_ledger="$(harness_psql "$db" -tAc 'SELECT count(*) FROM realtime.schema_migrations' 2>/dev/null || echo 0)"
  before_partitions="$(harness_psql "$db" -tAc "SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'realtime' AND c.relname LIKE 'messages_%'" 2>/dev/null || echo 0)"
  if [[ "$variant" == changed ]]; then
    [[ "$before_metadata" -gt 0 && "$before_tenant" == "$before_ledger" && "$before_ledger" -gt 0 && "$before_partitions" -gt 0 ]] || fail "changed native prepare did not complete catalog setup on trial $trial"
  fi

  local port=4000 logfile="$RUNNER_TEMP/${variant}-${trial}-server.log" total_started ready_at
  total_started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  start_host_service realtime "$logfile" "${rt_env[@]}" -- "$rootfs/bin/server"
  if ! wait_for_native_ready "$port" "$host_service_pid" "$logfile"; then
    cat "$logfile" >&2
    fail "$variant server failed to become ready on trial $trial"
  fi
  ready_at="$(python3 -c 'import time; print(time.monotonic_ns())')"
  local stop_started stop_ms
  stop_started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  kill -TERM "$host_service_pid"
  wait "$host_service_pid" 2>/dev/null || true
  stop_ms="$(( ($(python3 -c 'import time; print(time.monotonic_ns())') - stop_started) / 1000000 ))"
  local full_ms="$(( (ready_at - total_started) / 1000000 ))"
  local metadata tenant_progress tenant_ledger partitions
  metadata="$(harness_psql "$db" -tAc 'SELECT count(*) FROM _realtime.schema_migrations')"
  tenant_progress="$(harness_psql "$db" -tAc "SELECT migrations_ran FROM _realtime.tenants WHERE external_id = 'realtime-dev'")"
  tenant_ledger="$(harness_psql "$db" -tAc 'SELECT count(*) FROM realtime.schema_migrations')"
  partitions="$(harness_psql "$db" -tAc "SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'realtime' AND c.relname LIKE 'messages_%'")"
  [[ "$metadata" -gt 0 && "$tenant_progress" == "$tenant_ledger" && "$tenant_ledger" -gt 0 && "$partitions" -gt 0 ]] || fail "$variant native readiness state incomplete on trial $trial"
  harness_psql "$db" -c "INSERT INTO realtime.messages(topic, extension, event, payload, private) VALUES ('benchmark-sentinel', 'broadcast', 'preserve', '{\"ok\":true}', true)" >/dev/null
  local rerun_started rerun_ms
  rerun_started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  env "${rt_env[@]}" SEED_SELF_HOST=true "$rootfs/bin/prepare" >"$RUNNER_TEMP/${variant}-${trial}-rerun.log" 2>&1 || {
    cat "$RUNNER_TEMP/${variant}-${trial}-rerun.log" >&2
    fail "$variant repeat preparation failed on trial $trial"
  }
  rerun_ms="$(( ($(python3 -c 'import time; print(time.monotonic_ns())') - rerun_started) / 1000000 ))"
  local sentinel_count
  sentinel_count="$(harness_psql "$db" -tAc "SELECT count(*) FROM realtime.messages WHERE topic='benchmark-sentinel' AND event='preserve'")"
  [[ "$sentinel_count" == 1 ]] || fail "$variant preparation changed sentinel data on trial $trial"
  printf '{"runtime":"native","variant":"%s","trial":%s,"prepare_ms":%s,"prepare_state":{"metadata_migrations":%s,"tenant_migrations_recorded":%s,"tenant_migration_ledger":%s,"partitions":%s},"server_ready_after_prepare_ms":%s,"prepare_plus_server_ready_ms":%s,"ready_state":{"metadata_migrations":%s,"tenant_migrations_recorded":%s,"tenant_migration_ledger":%s,"partitions":%s},"shutdown_ms":%s,"repeat_prepare_ms":%s,"rerun_sentinel_count":%s}\n' \
    "$variant" "$trial" "$prep_ms" "$before_metadata" "$before_tenant" "$before_ledger" "$before_partitions" "$full_ms" "$((prep_ms + full_ms))" "$metadata" "$tenant_progress" "$tenant_ledger" "$partitions" "$stop_ms" "$rerun_ms" "$sentinel_count" >> "$results_file"
}

measure_docker() {
  local variant="$1" image="$2" trial="$3"
  local prepare_db="rt_docker_prepare_${variant}_${trial}" db="rt_docker_full_${variant}_${trial}"
  local envs_base=()
  while IFS= read -r pair; do envs_base+=(-e "$pair"); done < <(runtime_env_pairs realtime)
  envs_base+=(-e DB_HOST="$POSTGRES_CONTAINER" -e DB_PORT=5432 -e DB_USER=supabase_admin -e DB_PASSWORD=postgres
    -e DB_ENC_KEY=0123456789abcdef -e DB_AFTER_CONNECT_QUERY='SET search_path TO _realtime'
    -e API_JWT_SECRET="$api_secret" -e METRICS_JWT_SECRET="$metrics_secret"
    -e SECRET_KEY_BASE="$secret_key_base" -e APP_NAME=benchmark -e SEED_SELF_HOST=true)
  harness_psql postgres -c "CREATE DATABASE $prepare_db" >/dev/null
  harness_psql "$prepare_db" -c 'CREATE SCHEMA IF NOT EXISTS _realtime' >/dev/null
  local prep_envs=("${envs_base[@]}" -e DB_NAME="$prepare_db")
  local prep_started prep_ms
  prep_started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  docker run --rm --network "$NETWORK" --entrypoint /app/bin/prepare "${prep_envs[@]}" "$image" >"$RUNNER_TEMP/${variant}-${trial}-docker-prepare.log" 2>&1 || {
    cat "$RUNNER_TEMP/${variant}-${trial}-docker-prepare.log" >&2
    fail "$variant Docker prepare failed on trial $trial"
  }
  prep_ms="$(( ($(python3 -c 'import time; print(time.monotonic_ns())') - prep_started) / 1000000 ))"
  local before_metadata before_tenant before_ledger before_partitions
  before_metadata="$(harness_psql "$prepare_db" -tAc 'SELECT count(*) FROM _realtime.schema_migrations')"
  before_tenant="$(harness_psql "$prepare_db" -tAc "SELECT COALESCE((SELECT migrations_ran FROM _realtime.tenants WHERE external_id = 'realtime-dev'), -1)")"
  before_ledger="$(harness_psql "$prepare_db" -tAc 'SELECT count(*) FROM realtime.schema_migrations' 2>/dev/null || echo 0)"
  before_partitions="$(harness_psql "$prepare_db" -tAc "SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'realtime' AND c.relname LIKE 'messages_%'" 2>/dev/null || echo 0)"
  if [[ "$variant" == changed ]]; then
    [[ "$before_metadata" -gt 0 && "$before_tenant" == "$before_ledger" && "$before_ledger" -gt 0 && "$before_partitions" -gt 0 ]] || fail "changed Docker prepare did not complete catalog setup on trial $trial"
  fi

  harness_psql postgres -c "CREATE DATABASE $db" >/dev/null
  harness_psql "$db" -c 'CREATE SCHEMA IF NOT EXISTS _realtime' >/dev/null
  local envs=("${envs_base[@]}" -e DB_NAME="$db")
  local name="rt-bench-${variant}-${trial}" started port
  started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  run_container "$name" --network "$NETWORK" -p 127.0.0.1::4000 "${envs[@]}" "$image"
  port="$(host_port "$name" 4000)"
  if ! wait_for_docker_ready "$port" "$name"; then
    container_logs "$name"
    fail "$variant Docker Realtime failed to become ready on trial $trial"
  fi
  local ready full_ms
  ready="$(python3 -c 'import time; print(time.monotonic_ns())')"
  full_ms="$(( (ready - started) / 1000000 ))"
  local migration_count tenant_progress tenant_migration_count partition_count
  migration_count="$(harness_psql "$db" -tAc 'SELECT count(*) FROM _realtime.schema_migrations')"
  tenant_progress="$(harness_psql "$db" -tAc "SELECT migrations_ran FROM _realtime.tenants WHERE external_id = 'realtime-dev'")"
  tenant_migration_count="$(harness_psql "$db" -tAc 'SELECT count(*) FROM realtime.schema_migrations')"
  partition_count="$(harness_psql "$db" -tAc "SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'realtime' AND c.relname LIKE 'messages_%'")"
  [[ "$migration_count" -gt 0 && "$tenant_progress" == "$tenant_migration_count" && "$tenant_migration_count" -gt 0 && "$partition_count" -gt 0 ]] || fail "$variant Docker readiness state incomplete on trial $trial"
  harness_psql "$db" -c "INSERT INTO realtime.messages(topic, extension, event, payload, private) VALUES ('benchmark-sentinel', 'broadcast', 'preserve', '{\"ok\":true}', true)" >/dev/null
  local stop_started stop_ms
  stop_started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  docker stop --time 10 "$name" >/dev/null
  docker rm "$name" >/dev/null
  stop_ms="$(( ($(python3 -c 'import time; print(time.monotonic_ns())') - stop_started) / 1000000 ))"
  local repeat_started repeat_ms full_sentinel
  repeat_started="$(python3 -c 'import time; print(time.monotonic_ns())')"
  docker run --rm --network "$NETWORK" --entrypoint /app/bin/prepare "${envs[@]}" "$image" >"$RUNNER_TEMP/${variant}-${trial}-docker-rerun.log" 2>&1 || fail "$variant Docker rerun failed on trial $trial"
  repeat_ms="$(( ($(python3 -c 'import time; print(time.monotonic_ns())') - repeat_started) / 1000000 ))"
  full_sentinel="$(harness_psql "$db" -tAc "SELECT count(*) FROM realtime.messages WHERE topic='benchmark-sentinel' AND event='preserve'")"
  [[ "$full_sentinel" == 1 ]] || fail "$variant Docker preparation changed sentinel data on trial $trial"
  printf '{"runtime":"docker","variant":"%s","trial":%s,"prepare_ms":%s,"prepare_state":{"metadata_migrations":%s,"tenant_migrations_recorded":%s,"tenant_migration_ledger":%s,"partitions":%s},"container_ready_ms":%s,"ready_state":{"metadata_migrations":%s,"tenant_migrations_recorded":%s,"tenant_migration_ledger":%s,"partitions":%s},"shutdown_ms":%s,"repeat_prepare_ms":%s,"rerun_sentinel_count":%s}\n' \
    "$variant" "$trial" "$prep_ms" "$before_metadata" "$before_tenant" "$before_ledger" "$before_partitions" "$full_ms" "$migration_count" "$tenant_progress" "$tenant_migration_count" "$partition_count" "$stop_ms" "$repeat_ms" "$full_sentinel" >> "$results_file"
}

wait_for_native_ready() {
  local port="$1" pid="$2" logfile="$3" start_ms now_ms
  start_ms="$(date +%s%3N)"
  while :; do
    now_ms="$(date +%s%3N)"
    (( now_ms - start_ms < 180000 )) || break
    kill -0 "$pid" 2>/dev/null || { cat "$logfile" >&2; return 1; }
    local health ping
    health="$(curl -sS --max-time 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/healthcheck" 2>/dev/null || true)"
    ping="$(curl -sS --max-time 1 -o /dev/null -w '%{http_code}' -H 'Host: realtime-dev' "http://127.0.0.1:$port/api/ping" 2>/dev/null || true)"
    [[ "$health" == 200 && "$ping" == 200 ]] && return 0
    sleep 0.25
  done
  cat "$logfile" >&2
  return 1
}

wait_for_docker_ready() {
  local port="$1" container="$2" start_ms now_ms
  start_ms="$(date +%s%3N)"
  while :; do
    now_ms="$(date +%s%3N)"
    (( now_ms - start_ms < 180000 )) || break
    [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || printf false)" == true ]] || return 1
    local health ping
    health="$(curl -sS --max-time 1 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/healthcheck" 2>/dev/null || true)"
    ping="$(curl -sS --max-time 1 -o /dev/null -w '%{http_code}' -H 'Host: realtime-dev' "http://127.0.0.1:$port/api/ping" 2>/dev/null || true)"
    [[ "$health" == 200 && "$ping" == 200 ]] && return 0
    sleep 0.25
  done
  container_logs "$container"
  return 1
}

for ((trial = 1; trial <= SAMPLES; trial++)); do
  if (( trial % 2 == 1 )); then
    measure_native baseline "$BASE_ROOTFS" "$trial"
    measure_native changed "$CHANGED_ROOTFS" "$trial"
    measure_docker baseline "$BASE_IMAGE" "$trial"
    measure_docker changed "$CHANGED_IMAGE" "$trial"
  else
    measure_native changed "$CHANGED_ROOTFS" "$trial"
    measure_native baseline "$BASE_ROOTFS" "$trial"
    measure_docker changed "$CHANGED_IMAGE" "$trial"
    measure_docker baseline "$BASE_IMAGE" "$trial"
  fi
done

python3 - "$results_file" "$OUTPUT" <<'PY'
import json
import pathlib
import sys

rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
summary = {}
for runtime in sorted({row["runtime"] for row in rows}):
    summary[runtime] = {}
    for variant in ("baseline", "changed"):
        selected = [row for row in rows if row["runtime"] == runtime and row["variant"] == variant]
        fields = sorted({key for row in selected for key in row if key.endswith("_ms")})
        summary[runtime][variant] = {
            field: round(__import__("statistics").median(row[field] for row in selected), 1)
            for field in fields if all(field in row for row in selected)
        }
doc = {
    "status": "complete",
    "baseline": {"source": "published realtime-v2.134.5 artifact before PR 324"},
    "changed": {"source": "PR 324 validation-only build at " + __import__("os").environ.get("CANDIDATE_COMMIT", "unknown")},
    "artifacts": {
        "baseline_archive_sha256": __import__("os").environ.get("BASE_ARCHIVE_SHA256"),
        "changed_archive_sha256": __import__("os").environ.get("CHANGED_ARCHIVE_SHA256"),
        "baseline_image_id": __import__("os").environ.get("BASE_IMAGE_ID"),
        "changed_image_id": __import__("os").environ.get("CHANGED_IMAGE_ID"),
    },
    "runner": {"os": "Ubuntu 22.04", "runtime": ["native artifact", "Docker image"], "readiness": "HTTP /healthcheck and /api/ping with Host: realtime-dev; 250ms retry interval"},
    "median_ms": summary,
    "samples": rows,
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(doc, indent=2) + "\n")
PY
cat "$OUTPUT"
benchmark_complete=1
