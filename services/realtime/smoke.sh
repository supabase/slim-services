#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

require_cmd docker
require_cmd curl
require_cmd openssl
image="${IMAGE:?set IMAGE to the image tag to smoke test}"
ensure_image "$image"

log "checking realtime slim runtime commands"
docker run --rm --entrypoint /usr/bin/sh "$image" -c '
  set -eu
  for bin in awk base64 cat chmod curl date grep head hostname mv od openssl rm setpriv sh tini tr; do
    test -x "/usr/bin/${bin}"
  done
  /usr/bin/curl --version >/dev/null
  /usr/bin/openssl version >/dev/null
'

log "checking generated certs fail fast without AWS env"
cert_output="$(
  docker run --rm --entrypoint /usr/bin/sh \
    -e GENERATE_CLUSTER_CERTS=true \
    "$image" /app/run.sh true 2>&1 || true
)"
if ! printf '%s' "$cert_output" | grep -q 'AWS_CONTAINER_CREDENTIALS_RELATIVE_URI is required'; then
  printf '%s\n' "$cert_output" >&2
  fail "realtime generated certs path did not fail with the expected missing-env error"
fi

log "checking AWS metadata IPv6 parser overlay"
metadata_ip="$(
  awk '
    BEGIN {
      data = "{\"Networks\":[{\"IPv6Addresses\":[\"fd00::1\",\"2600:1f18:abcd::42\"]}]}"
      if (match(data, /"IPv6Addresses"[[:space:]]*:[[:space:]]*\[/)) {
        s = substr(data, RSTART + RLENGTH)
        while (match(s, /"([^"\\]|\\.)*"/)) {
          value = substr(s, RSTART + 1, RLENGTH - 2)
          print value
          s = substr(s, RSTART + RLENGTH)
          if (match(s, /^[[:space:]]*\]/)) {
            exit
          }
        }
      }
    }
  ' | grep -Ev '^f[cd]' | head -1
)"
if [[ "$metadata_ip" != "2600:1f18:abcd::42" ]]; then
  fail "realtime AWS metadata parser did not select the public IPv6 address"
fi

start_postgres realtime_smoke

api_secret='realtime-api-secret-with-at-least-32-characters'
metrics_secret='realtime-metrics-secret-with-at-least-32'
secret_key_base="$(openssl rand -hex 32)"

container="realtime-smoke-$RUN_ID"
run_container \
  "$container" \
  --network "$NETWORK" \
  -p 127.0.0.1::4000 \
  -e DB_HOST="$POSTGRES_CONTAINER" \
  -e DB_PORT=5432 \
  -e DB_USER=postgres \
  -e DB_PASSWORD=postgres \
  -e DB_NAME=realtime_smoke \
  -e DB_ENC_KEY=0123456789abcdef \
  -e API_JWT_SECRET="$api_secret" \
  -e METRICS_JWT_SECRET="$metrics_secret" \
  -e SECRET_KEY_BASE="$secret_key_base" \
  -e APP_NAME=realtime-smoke \
  -e SEED_SELF_HOST=true \
  "$image"
port="$(host_port "$container" 4000)"

log "smoke testing realtime on port $port"
if ! wait_for_http_code "http://127.0.0.1:$port/healthcheck" "200" 180 "" "$container"; then
  container_logs "$container"
  fail "realtime /healthcheck did not return 200"
fi
record_runtime_metrics "$container"
log "realtime smoke passed"
