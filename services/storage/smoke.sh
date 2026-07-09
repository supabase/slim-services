#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd curl
require_cmd openssl

image="${IMAGE:-}"
artifact_rootfs="${ARTIFACT_ROOTFS:-}"

if [[ -n "$image" && -n "$artifact_rootfs" ]]; then
  fail "set only one of IMAGE or ARTIFACT_ROOTFS"
fi
if [[ -z "$image" && -z "$artifact_rootfs" ]]; then
  fail "set IMAGE to smoke a Docker image, or ARTIFACT_ROOTFS to smoke an extracted artifact"
fi
if [[ -n "$image" || "${SLIM_SMOKE_HOST_POSTGRES:-0}" != "1" ]]; then
  require_cmd docker
fi

start_postgres storage_smoke

jwt_secret='storage-jwt-secret-with-at-least-32-characters'

# Full object round-trip on the file backend: bucket create, upload, download.
# The generic smoke postgres has no supabase grants; give service_role access
# to the storage schema created by the boot migrations first.
storage_object_roundtrip() {
  local port="$1"
  local on_failure="$2"

  harness_psql storage_smoke >/dev/null <<'SQL'
GRANT USAGE ON SCHEMA storage TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA storage TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA storage TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA storage TO service_role;
SQL

  local service_jwt body
  service_jwt="$(make_role_jwt "$jwt_secret" service_role)"
  curl -fsS -X POST \
    -H "Authorization: Bearer $service_jwt" \
    -H 'Content-Type: application/json' \
    -d '{"name":"smoke-bucket"}' \
    "http://127.0.0.1:$port/bucket" >/dev/null \
    || { $on_failure; fail "storage bucket creation failed"; }
  curl -fsS -X POST \
    -H "Authorization: Bearer $service_jwt" \
    -H 'Content-Type: text/plain' \
    --data-binary 'hello-slim' \
    "http://127.0.0.1:$port/object/smoke-bucket/hello.txt" >/dev/null \
    || { $on_failure; fail "storage object upload failed"; }
  body="$(curl -fsS -H "Authorization: Bearer $service_jwt" \
    "http://127.0.0.1:$port/object/smoke-bucket/hello.txt")"
  [[ "$body" == "hello-slim" ]] \
    || { $on_failure; fail "storage object download mismatch: $body"; }
}

if [[ -n "$artifact_rootfs" ]]; then
  # Host-process smoke. The artifact bundles its Node runtime; the wrapper
  # must find it with no help — SUPABASE_NODE stays unset and PATH is
  # sanitized so a host node cannot mask a broken bundle.
  require_cmd python3

  storage_data_dir=""
  cleanup_storage_smoke() {
    rm -f "${storage_log:-}"
    if [[ -n "$storage_data_dir" ]]; then
      rm -rf "$storage_data_dir"
    fi
    cleanup_smoke
  }
  trap cleanup_storage_smoke EXIT

  storage_bin="$artifact_rootfs/bin/storage"
  [[ -x "$storage_bin" ]] || fail "storage artifact launcher not found or not executable: $storage_bin"

  [[ -x "$artifact_rootfs/node/bin/node" ]] \
    || fail "storage artifact does not bundle a node runtime: $artifact_rootfs/node/bin/node"

  pg_port="$(postgres_port)"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  storage_log="$(mktemp "${TMPDIR:-/tmp}/storage-smoke.XXXXXX.log")"
  storage_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/storage-smoke-data.XXXXXX")"

  log "smoke testing storage host process on port $port"
  start_host_service storage "$storage_log" \
    SUPABASE_NODE= \
    PATH=/usr/bin:/bin \
    SERVER_PORT="$port" \
    SERVER_HOST=127.0.0.1 \
    DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:$pg_port/storage_smoke" \
    AUTH_JWT_SECRET="$jwt_secret" \
    PGRST_JWT_SECRET="$jwt_secret" \
    STORAGE_BACKEND=file \
    FILE_STORAGE_BACKEND_PATH="$storage_data_dir" \
    -- "$storage_bin"

  if ! wait_for_http_code_host "http://127.0.0.1:$port/status" "200" 120 "$host_service_pid" "$storage_log"; then
    fail "storage /status did not return 200"
  fi

  log "smoke testing storage object round-trip"
  print_storage_host_logs() {
    printf '\n[slim-smoke] storage host process logs\n' >&2
    cat "$storage_log" >&2 || true
  }
  storage_object_roundtrip "$port" print_storage_host_logs

  record_host_runtime_metrics "$host_service_pid"
  log "storage smoke passed"
  exit 0
fi

ensure_image "$image"

container="storage-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::5000 \
  -e DATABASE_URL="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/storage_smoke" \
  -e AUTH_JWT_SECRET="$jwt_secret" \
  -e PGRST_JWT_SECRET="$jwt_secret" \
  -e STORAGE_BACKEND=file \
  -e FILE_STORAGE_BACKEND_PATH=/tmp/storage \
  "$image"
port="$(host_port "$container" 5000)"

log "smoke testing storage on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/status" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "storage /status did not return 200"
fi

log "smoke testing storage object round-trip"
print_storage_container_logs() {
  container_logs "$container"
}
storage_object_roundtrip "$port" print_storage_container_logs

record_runtime_metrics "$container"
log "storage smoke passed"
