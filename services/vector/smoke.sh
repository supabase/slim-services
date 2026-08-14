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

task_dir="$(mktemp -d "${TMPDIR:-/tmp}/vector-smoke.XXXXXX")"
input_dir="$task_dir/input"
output_dir="$task_dir/output"
state_dir="$task_dir/state"
config="$task_dir/vector.yaml"
smoke_log="$task_dir/vector.log"
mkdir -p "$input_dir" "$output_dir" "$state_dir"
container=""
host_service_pid=""

cleanup_vector_smoke() {
  set +e
  cleanup_smoke
  if [[ -d "$task_dir" ]]; then
    rm -rf "$task_dir"
  fi
}
trap cleanup_vector_smoke EXIT

first_id="vector-smoke-${RUN_ID}-first"
second_id="vector-smoke-${RUN_ID}-second"

if [[ -n "$artifact_rootfs" ]]; then
  config_data_dir="$state_dir"
  config_input="$input_dir/events.log"
  config_output="$output_dir/events.json"
else
  config_data_dir="/smoke/state"
  config_input="/smoke/input/events.log"
  config_output="/smoke/output/events.json"
fi

cat >"$config" <<EOF
data_dir: $config_data_dir

sources:
  smoke_input:
    type: file
    include:
      - $config_input
    read_from: beginning

transforms:
  smoke_transform:
    type: remap
    inputs:
      - smoke_input
    source: |
      . = parse_json!(.message)
      .smoke_marker = "vector-smoke"
      .transformed = true

sinks:
  smoke_output:
    type: file
    inputs:
      - smoke_transform
    path: $config_output
    encoding:
      codec: json
EOF

vector_bin=""
if [[ -n "$artifact_rootfs" ]]; then
  vector_bin="$artifact_rootfs/bin/vector"
  [[ -x "$vector_bin" ]] || fail "Vector artifact binary not found or not executable: $vector_bin"
fi

run_vector_validate() {
  if [[ -n "$artifact_rootfs" ]]; then
    "$vector_bin" validate --config-yaml "$config"
  else
    docker run --rm \
      --entrypoint /usr/local/bin/vector \
      -e VECTOR_THREADS=1 \
      -v "$task_dir:/smoke" \
      "$image" validate --config-yaml /smoke/vector.yaml
  fi
}

start_vector() {
  if [[ -n "$artifact_rootfs" ]]; then
    start_host_service vector "$smoke_log" -- "$vector_bin" --config-yaml "$config"
  else
    container="vector-smoke-$RUN_ID"
    run_container \
      "$container" \
      --entrypoint /usr/local/bin/vector \
      -e VECTOR_THREADS=1 \
      -v "$task_dir:/smoke" \
      "$image" \
      --config-yaml /smoke/vector.yaml
  fi
}

stop_vector() {
  if [[ -n "$artifact_rootfs" ]]; then
    if [[ -n "${host_service_pid:-}" ]] && kill -0 "$host_service_pid" >/dev/null 2>&1; then
      kill "$host_service_pid" >/dev/null 2>&1 || true
      wait "$host_service_pid" >/dev/null 2>&1 || true
    fi
    host_service_pid=""
  elif [[ -n "$container" ]]; then
    if [[ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || printf false)" == "true" ]]; then
      docker stop "$container" >/dev/null || {
        container_logs "$container"
        fail "Vector container did not stop"
      }
    fi
    docker rm "$container" >/dev/null 2>&1 || true
    container=""
  fi
}

show_vector_logs() {
  if [[ -n "$artifact_rootfs" ]]; then
    printf '\n[slim-smoke] Vector host process logs\n' >&2
    cat "$smoke_log" >&2 || true
  elif [[ -n "$container" ]]; then
    container_logs "$container"
  fi
}

wait_for_events() {
  local expected_count="$1"
  local timeout="${2:-60}"
  if ! python3 - "$output_dir/events.json" "$first_id" "$second_id" "$expected_count" "$timeout" <<'PY'
import json
import pathlib
import sys
import time

path, first_id, second_id, expected_count, timeout = sys.argv[1:]
expected_count = int(expected_count)
deadline = time.monotonic() + int(timeout)
while time.monotonic() < deadline:
    records = []
    try:
        lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
        records = [json.loads(line) for line in lines if line.strip()]
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    ids = [record.get("event_id") for record in records]
    if (
        len(records) == expected_count
        and ids.count(first_id) == 1
        and (expected_count == 1 or ids.count(second_id) == 1)
        and all(record.get("smoke_marker") == "vector-smoke" for record in records)
        and all(record.get("transformed") is True for record in records)
    ):
        print(json.dumps(records, sort_keys=True))
        raise SystemExit(0)
    time.sleep(0.5)
print(f"timed out waiting for exactly {expected_count} transformed events", file=sys.stderr)
raise SystemExit(1)
PY
  then
    show_vector_logs
    fail "Vector file source/remap/file sink smoke failed"
  fi
}

run_vector_validate || {
  show_vector_logs
  fail "Vector configuration validation failed"
}

log "starting Vector file source -> VRL remap -> file sink smoke"
start_vector
printf '{"event_id":"%s","message":"first event"}\n' "$first_id" >>"$input_dir/events.log"
wait_for_events 1

log "stopping and restarting Vector with the same state directory"
stop_vector
start_vector
printf '{"event_id":"%s","message":"second event"}\n' "$second_id" >>"$input_dir/events.log"
wait_for_events 2

if [[ -n "$artifact_rootfs" ]]; then
  record_host_runtime_metrics "$host_service_pid"
else
  record_runtime_metrics "$container"
fi

log "Vector smoke passed with exactly-once transformed output"
