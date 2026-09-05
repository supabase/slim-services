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

start_postgres pooler_smoke

api_secret='pooler-api-secret-with-at-least-32-characters'
metrics_secret='pooler-metrics-secret-with-at-least-32'
secret_key_base="$(openssl rand -hex 32)"
# Supavisor's Cloak AES-GCM vault key is a 32-byte printable value. This
# matches the CLI's unpadded base64url generator (24 random bytes -> 32 chars).
vault_enc_key="$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=[:space:]')"
[[ "${#vault_enc_key}" == "32" ]] || fail "generated pooler vault key is not 32 bytes"
token="$(make_role_jwt "$api_secret" "service_role")"

if [[ -n "$artifact_rootfs" ]]; then
  # Host-process smoke: the artifact is a self-contained mix release run
  # directly on the host.
  require_cmd python3

  cleanup_pooler_smoke() {
    rm -f "${pooler_log:-}"
    cleanup_smoke
  }
  trap cleanup_pooler_smoke EXIT

  pooler_bin="$artifact_rootfs/bin/supavisor"
  [[ -x "$pooler_bin" ]] || fail "pooler artifact launcher not found or not executable: $pooler_bin"
  [[ -x "$artifact_rootfs/bin/prepare" ]] || fail "pooler preparation helper not found or not executable: $artifact_rootfs/bin/prepare"
  [[ -x "$artifact_rootfs/bin/provision-tenant" ]] || fail "pooler tenant helper not found or not executable: $artifact_rootfs/bin/provision-tenant"
  [[ -f "$artifact_rootfs/share/supabase-cli/provision-tenant.exs" ]] \
    || fail "pooler tenant Elixir helper not found: $artifact_rootfs/share/supabase-cli/provision-tenant.exs"

  pg_port="$(postgres_port)"
  port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
  pooler_log="$(mktemp "${TMPDIR:-/tmp}/pooler-smoke.XXXXXX.log")"

  pooler_env=(
    DATABASE_URL="ecto://postgres:postgres@127.0.0.1:$pg_port/pooler_smoke"
    SECRET_KEY_BASE="$secret_key_base"
    API_JWT_SECRET="$api_secret"
    METRICS_JWT_SECRET="$metrics_secret"
    VAULT_ENC_KEY="$vault_enc_key"
    PORT="$port"
    RELEASE_DISTRIBUTION=none
  )
  smoke_beam_release_distribution "$pooler_bin" "${pooler_env[@]}"

  log "running pooler preparation"
  if ! env "${pooler_env[@]}" "$artifact_rootfs/bin/prepare" >"$pooler_log" 2>&1; then
    cat "$pooler_log" >&2
    fail "pooler preparation failed"
  fi

  provision_pooler_tenant() {
    env "${pooler_env[@]}" \
      POSTGRES_HOST=127.0.0.1 \
      POSTGRES_PORT="$pg_port" \
      POSTGRES_PASSWORD="$1" \
      TENANT_ID=pooler-smoke \
      POOL_MODE="$2" \
      DEFAULT_POOL_SIZE="$3" \
      MAX_CLIENT_CONN="$4" \
      "$artifact_rootfs/bin/provision-tenant" >>"$pooler_log" 2>&1
  }

  log "provisioning pooler tenant"
  provision_pooler_tenant postgres transaction 5 100
  log "repeating pooler tenant provisioning"
  provision_pooler_tenant postgres transaction 5 100
  log "updating pooler tenant with quoted password and settings"
  provision_pooler_tenant 'pooler "quoted" password \ slash' session 7 120
  provision_pooler_tenant 'pooler "quoted" password \ slash' session 7 120

  tenant_state="$(harness_psql pooler_smoke -tA <<'SQL'
SELECT format('%s|%s|%s|%s|%s|%s', count(DISTINCT t.id), max(t.default_pool_size),
  max(t.default_max_clients), count(u.id), max(u.pool_size), max(u.mode_type))
FROM _supavisor.tenants AS t
LEFT JOIN _supavisor.users AS u ON u.tenant_external_id = t.external_id
WHERE t.external_id = 'pooler-smoke';
SQL
)"
  [[ "$tenant_state" == "1|7|120|1|7|session" ]] \
    || fail "pooler tenant state mismatch after reprovisioning: $tenant_state"

  log "smoke testing pooler host process on port $port"
  start_host_service pooler "$pooler_log" \
    "${pooler_env[@]}" \
    -- "$artifact_rootfs/bin/server"

  if ! wait_for_http_code_host "http://127.0.0.1:$port/api/health" "204" 180 "$host_service_pid" "$pooler_log" "$token"; then
    fail "pooler /api/health did not return 204"
  fi
  record_host_runtime_metrics "$host_service_pid"
  log "pooler smoke passed"
  exit 0
fi

ensure_image "$image"

log "checking wget is on PATH (CLI healthcheck)"
docker run --rm --entrypoint /usr/bin/wget "$image" --help >/dev/null \
  || fail "pooler image is missing wget"
docker run --rm --entrypoint /usr/bin/sh "$image" -c \
  'test -x /app/bin/prepare && test -x /app/bin/provision-tenant && test -r /app/share/supabase-cli/provision-tenant.exs' \
  || fail "pooler image is missing service preparation helpers"

log "CLI one-shot: /app/bin/prepare"
docker run --rm --network "$NETWORK" \
  -e DATABASE_URL="ecto://postgres:postgres@$POSTGRES_CONTAINER:5432/pooler_smoke" \
  -e SECRET_KEY_BASE="$secret_key_base" \
  -e API_JWT_SECRET="$api_secret" \
  -e METRICS_JWT_SECRET="$metrics_secret" \
  -e VAULT_ENC_KEY="$vault_enc_key" \
  --entrypoint /app/bin/prepare \
  "$image" \
  || fail "pooler preparation one-shot failed"

provision_pooler_image_tenant() {
  docker run --rm --network "$NETWORK" \
    -e DATABASE_URL="ecto://postgres:postgres@$POSTGRES_CONTAINER:5432/pooler_smoke" \
    -e SECRET_KEY_BASE="$secret_key_base" \
    -e API_JWT_SECRET="$api_secret" \
    -e METRICS_JWT_SECRET="$metrics_secret" \
    -e VAULT_ENC_KEY="$vault_enc_key" \
    -e POSTGRES_HOST="$POSTGRES_CONTAINER" \
    -e POSTGRES_PORT=5432 \
    -e POSTGRES_PASSWORD="$1" \
    -e TENANT_ID=pooler-smoke \
    -e POOL_MODE="$2" \
    -e DEFAULT_POOL_SIZE="$3" \
    -e MAX_CLIENT_CONN="$4" \
    --entrypoint /app/bin/provision-tenant \
    "$image"
}

log "CLI one-shot: /app/bin/provision-tenant"
provision_pooler_image_tenant postgres transaction 5 100
provision_pooler_image_tenant postgres transaction 5 100
provision_pooler_image_tenant 'pooler "quoted" password \ slash' session 7 120
provision_pooler_image_tenant 'pooler "quoted" password \ slash' session 7 120

tenant_state="$(harness_psql pooler_smoke -tA <<'SQL'
SELECT format('%s|%s|%s|%s|%s|%s', count(DISTINCT t.id), max(t.default_pool_size),
  max(t.default_max_clients), count(u.id), max(u.pool_size), max(u.mode_type))
FROM _supavisor.tenants AS t
LEFT JOIN _supavisor.users AS u ON u.tenant_external_id = t.external_id
WHERE t.external_id = 'pooler-smoke';
SQL
)"
[[ "$tenant_state" == "1|7|120|1|7|session" ]] \
  || fail "pooler tenant state mismatch after image reprovisioning: $tenant_state"

container="pooler-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::4000 \
  -e DATABASE_URL="ecto://postgres:postgres@$POSTGRES_CONTAINER:5432/pooler_smoke" \
  -e SECRET_KEY_BASE="$secret_key_base" \
  -e API_JWT_SECRET="$api_secret" \
  -e METRICS_JWT_SECRET="$metrics_secret" \
  -e VAULT_ENC_KEY="$vault_enc_key" \
  "$image"
port="$(host_port "$container" 4000)"

log "smoke testing pooler on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/api/health" "204" 180 "$token" "$container"; then
  container_logs "$container"
  fail "pooler /api/health did not return 204"
fi
log "CLI health-cmd: wget --spider /api/health"
if ! docker exec "$container" wget -q --spider http://127.0.0.1:4000/api/health; then
  container_logs "$container"
  fail "pooler wget --spider /api/health failed"
fi
record_runtime_metrics "$container"
log "pooler smoke passed"
