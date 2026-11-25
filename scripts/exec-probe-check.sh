#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/exec-probe-check.sh SERVICE IMAGE

Prove IMAGE can run the Supabase CLI container healthcheck the way the CLI
starts it: /bin/sh -c "exec <probe>". The probe comes from HEALTHCHECK_PROBE
in services/SERVICE/recipe.env ("none" when the CLI has no bare CMD probe).

No server runs (--network none), so the probe itself failing is fine. Exit
126/127 means /bin/sh or the probe binary is missing or not a real
executable on PATH (a shell builtin cannot be exec'd); 125 means docker
could not start the container. Those fail the check.

Environment:
  PLATFORM=linux/ARCH   passed to docker run --platform when set
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

service="$1"
image="$2"
load_recipe "$service"

probe="${HEALTHCHECK_PROBE:-}"
[[ -n "$probe" ]] || fail "services/$service/recipe.env must set HEALTHCHECK_PROBE to the CLI healthcheck command, or to none"
if [[ "$probe" == "none" ]]; then
  log "exec-probe: $service declares no CLI CMD healthcheck probe"
  exit 0
fi

require_cmd docker
platform_args=()
[[ -z "${PLATFORM:-}" ]] || platform_args=(--platform "$PLATFORM")

log "exec-probe: $image: exec $probe"
set +e
output="$(
  docker run --rm --network none ${platform_args[@]+"${platform_args[@]}"} \
    --entrypoint /bin/sh "$image" -c "exec $probe" 2>&1
)"
status=$?
set -e

case "$status" in
  125|126|127)
    printf '%s\n' "$output" >&2
    fail "exec-probe: $service image cannot exec its CLI healthcheck probe (exit $status): $probe"
    ;;
esac
log "exec-probe: ok (probe exit $status without a server)"
