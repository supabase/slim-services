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
  [[ -x "$artifact_rootfs/bin/prepare" ]] || fail "storage preparation helper not found or not executable: $artifact_rootfs/bin/prepare"

  [[ -x "$artifact_rootfs/node/bin/node" ]] \
    || fail "storage artifact does not bundle a node runtime: $artifact_rootfs/node/bin/node"
  [[ -f "$artifact_rootfs/app/dist/scripts/migrate-call.js" ]] \
    || fail "storage artifact is missing dist/scripts/migrate-call.js"
  [[ -f "$artifact_rootfs/app/dist/scripts/migrations/0_create-migrations-table.sql" ]] \
    || fail "storage artifact is missing dist/scripts/migrations bootstrap SQL"

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

  log "running storage preparation"
  if ! env \
    SUPABASE_NODE= \
    PATH=/usr/bin:/bin \
    DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:$pg_port/storage_smoke" \
    AUTH_JWT_SECRET="$jwt_secret" \
    PGRST_JWT_SECRET="$jwt_secret" \
    STORAGE_BACKEND=file \
    FILE_STORAGE_BACKEND_PATH="$storage_data_dir" \
    "$artifact_rootfs/bin/prepare" >"$storage_log" 2>&1; then
    cat "$storage_log" >&2
    fail "storage preparation failed"
  fi

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

# shellcheck source=scripts/identity-lib.sh
source "$ROOT_DIR/scripts/identity-lib.sh"
load_recipe storage
identity_dir="$(mktemp -d "${TMPDIR:-/tmp}/storage-identity.XXXXXX")"
volume=""
cleanup_storage_image_smoke() {
  rm -rf "${identity_dir:-}"
  cleanup_smoke
  if [[ -n "${volume:-}" ]]; then
    docker volume rm -f "$volume" >/dev/null 2>&1 || true
  fi
}
trap cleanup_storage_image_smoke EXIT
if [[ "${SKIP_UPSTREAM_IDENTITY:-}" == "1" ]]; then
  fail "storage image smoke requires the digest-pinned upstream identity (unset SKIP_UPSTREAM_IDENTITY)"
fi
write_upstream_identity storage "$identity_dir"
assert_slim_matches_identity "$image" "$identity_dir/identity.env"
# shellcheck source=/dev/null
source "$identity_dir/identity.env"
pinned_image="$PINNED_IMAGE"

log "checking wget is on PATH (CLI healthcheck)"
docker run --rm --entrypoint /usr/bin/wget "$image" --help >/dev/null \
  || fail "storage image is missing wget"
docker run --rm --entrypoint /usr/bin/sh "$image" -c 'test -x /slim-runtime/bin/prepare' \
  || fail "storage image is missing the preparation helper"

storage_ep="$(docker inspect -f '{{json .Config.Entrypoint}}' "$image")"
[[ "$storage_ep" == "null" || "$storage_ep" == "[]" ]] \
  || fail "storage ENTRYPOINT is $storage_ep (expected empty)"
storage_cmd="$(docker inspect -f '{{json .Config.Cmd}}' "$image")"
[[ "$storage_cmd" == '["/slim-runtime/bin/storage"]' ]] \
  || fail "storage CMD is $storage_cmd (expected [/slim-runtime/bin/storage])"

log "CLI one-shot: /slim-runtime/bin/prepare"
if ! docker run --rm --network "$NETWORK" \
  -e DATABASE_URL="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/storage_smoke" \
  -e AUTH_JWT_SECRET="$jwt_secret" \
  -e PGRST_JWT_SECRET="$jwt_secret" \
  -e STORAGE_BACKEND=file \
  -e FILE_STORAGE_BACKEND_PATH=/mnt \
  -e TENANT_ID=stub \
  -e REGION=stub \
  -e GLOBAL_S3_BUCKET=stub \
  -w /app \
  --entrypoint /slim-runtime/bin/prepare \
  "$image"; then
  fail "storage preparation one-shot failed"
fi

# Run the file backend on a FRESH named volume mounted at /mnt — the exact
# docker.io stack layout — so the round-trip below proves the seeded volume
# root is writable, not just the container filesystem.
# Do not create_volume first: Docker seeds a new named volume from the
# image /mnt only on first mount.
volume="storage-smoke-vol-$RUN_ID"

container="storage-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::5000 \
  -v "$volume:/mnt" \
  -e DATABASE_URL="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/storage_smoke" \
  -e AUTH_JWT_SECRET="$jwt_secret" \
  -e PGRST_JWT_SECRET="$jwt_secret" \
  -e STORAGE_BACKEND=file \
  -e FILE_STORAGE_BACKEND_PATH=/mnt \
  "$image"
port="$(host_port "$container" 5000)"

log "smoke testing storage on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/status" "200" 120 "" "$container"; then
  container_logs "$container"
  fail "storage /status did not return 200"
fi

log "waiting for the baked HEALTHCHECK to report healthy"
if ! wait_for_container_healthy "$container" 60; then
  container_logs "$container"
  fail "storage container did not become healthy via the image HEALTHCHECK"
fi

log "smoke testing storage object round-trip"
print_storage_container_logs() {
  container_logs "$container"
}
storage_object_roundtrip "$port" print_storage_container_logs

record_runtime_metrics "$container"

log "leftover volume: docker.io -> slim"
vol_up="storage-leftover-up-$RUN_ID"
create_volume "$vol_up"
storage_leftover_up="storage-leftover-up-$RUN_ID"
run_container \
  "$storage_leftover_up" \
  --network "$NETWORK" \
  -p 127.0.0.1::5000 \
  -v "$vol_up:/mnt" \
  -e DATABASE_URL="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/storage_smoke" \
  -e AUTH_JWT_SECRET="$jwt_secret" \
  -e PGRST_JWT_SECRET="$jwt_secret" \
  -e STORAGE_BACKEND=file \
  -e FILE_STORAGE_BACKEND_PATH=/mnt \
  "$pinned_image"
up_port="$(host_port "$storage_leftover_up" 5000)"
if ! wait_for_http_code "http://127.0.0.1:$up_port/status" "200" 120 "" "$storage_leftover_up"; then
  container_logs "$storage_leftover_up"
  fail "upstream leftover storage /status did not return 200"
fi
leftover_jwt="$(make_role_jwt "$jwt_secret" service_role)"
curl -fsS -X POST \
  -H "Authorization: Bearer $leftover_jwt" \
  -H 'Content-Type: application/json' \
  -d '{"name":"leftover-up"}' \
  "http://127.0.0.1:$up_port/bucket" >/dev/null \
  || { container_logs "$storage_leftover_up"; fail "leftover-up bucket create failed"; }
curl -fsS -X POST \
  -H "Authorization: Bearer $leftover_jwt" \
  -H 'Content-Type: text/plain' \
  --data-binary 'leftover-from-dockerio' \
  "http://127.0.0.1:$up_port/object/leftover-up/hello.txt" >/dev/null \
  || { container_logs "$storage_leftover_up"; fail "leftover-up upload failed"; }
docker rm -f "$storage_leftover_up" >/dev/null
storage_leftover_slim="storage-leftover-slim-$RUN_ID"
run_container \
  "$storage_leftover_slim" \
  --network "$NETWORK" \
  -p 127.0.0.1::5000 \
  -v "$vol_up:/mnt" \
  -e DATABASE_URL="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/storage_smoke" \
  -e AUTH_JWT_SECRET="$jwt_secret" \
  -e PGRST_JWT_SECRET="$jwt_secret" \
  -e STORAGE_BACKEND=file \
  -e FILE_STORAGE_BACKEND_PATH=/mnt \
  "$image"
slim_port="$(host_port "$storage_leftover_slim" 5000)"
if ! wait_for_http_code "http://127.0.0.1:$slim_port/status" "200" 120 "" "$storage_leftover_slim"; then
  container_logs "$storage_leftover_slim"
  fail "slim could not serve a docker.io leftover /mnt"
fi
body="$(curl -fsS -H "Authorization: Bearer $leftover_jwt" \
  "http://127.0.0.1:$slim_port/object/leftover-up/hello.txt")"
[[ "$body" == "leftover-from-dockerio" ]] || fail "slim leftover download mismatch: $body"

log "imgproxy-pin sidecar can read leftover /mnt objects"
imgproxy_sidecar_uid() {
  local ref="${IMGPROXY_UPSTREAM_IMAGE:-ghcr.io/imgproxy/imgproxy:v3.8.0@sha256:75fcf5f5a72bc4bce354d1b5dfb4636a2e6979f0ce68cdacc51ed1bce2ab494e}"
  local user
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    pull_pinned_image "$ref"
  fi
  user="$(image_config_user "$ref")"
  if [[ -z "$user" || "$user" == "root" ]]; then
    printf '0'
    return 0
  fi
  if [[ "$user" =~ ^[0-9]+$ ]]; then
    printf '%s' "$user"
    return 0
  fi
  run_in_pin "$ref" id -u "$user"
}
sidecar_uid="$(imgproxy_sidecar_uid)"
object_path="$(docker run --rm -v "$vol_up:/mnt:ro" --entrypoint /node/bin/node "$image" -e '
const fs = require("node:fs");
function walk(dir) {
  for (const name of fs.readdirSync(dir)) {
    const path = dir + "/" + name;
    if (fs.statSync(path).isDirectory()) walk(path);
    else { console.log(path); process.exit(0); }
  }
}
walk("/mnt");
process.exit(1);
')"
[[ -n "$object_path" ]] || fail "no leftover object on /mnt for sidecar read"
sidecar_body="$(docker run --rm --user "$sidecar_uid" -v "$vol_up:/mnt:ro" \
  --entrypoint /node/bin/node "$image" -e \
  'console.log(require("node:fs").readFileSync(process.argv[1], "utf8"))' \
  "$object_path")" \
  || fail "imgproxy uid $sidecar_uid could not read $object_path"
[[ -n "$sidecar_body" ]] || fail "imgproxy sidecar read empty object"

log "leftover volume: slim -> docker.io"
docker rm -f "$container" >/dev/null
run_container \
  "storage-leftover-up2-$RUN_ID" \
  --network "$NETWORK" \
  -p 127.0.0.1::5000 \
  -v "$volume:/mnt" \
  -e DATABASE_URL="postgresql://postgres:postgres@$POSTGRES_CONTAINER:5432/storage_smoke" \
  -e AUTH_JWT_SECRET="$jwt_secret" \
  -e PGRST_JWT_SECRET="$jwt_secret" \
  -e STORAGE_BACKEND=file \
  -e FILE_STORAGE_BACKEND_PATH=/mnt \
  "$pinned_image"
up2_port="$(host_port "storage-leftover-up2-$RUN_ID" 5000)"
if ! wait_for_http_code "http://127.0.0.1:$up2_port/status" "200" 120 "" "storage-leftover-up2-$RUN_ID"; then
  container_logs "storage-leftover-up2-$RUN_ID"
  fail "docker.io could not serve a slim leftover /mnt"
fi
body="$(curl -fsS -H "Authorization: Bearer $(make_role_jwt "$jwt_secret" service_role)" \
  "http://127.0.0.1:$up2_port/object/smoke-bucket/hello.txt")"
[[ "$body" == "hello-slim" ]] || fail "docker.io leftover download mismatch: $body"

log "storage smoke passed"
