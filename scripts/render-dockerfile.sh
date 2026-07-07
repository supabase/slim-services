#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/render-dockerfile.sh SERVICE

Print the service's final slim Dockerfile to stdout: Dockerfile.slim plus ENV
lines generated from services/SERVICE/runtime.env (the runtime profile
contract). Every image build MUST go through this rendering — building
Dockerfile.slim directly would silently skip the runtime profile.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

require_cmd python3

service="$1"
is_service "$service" || fail "unknown service: $service"

dockerfile="$(service_dir "$service")/Dockerfile.slim"
[[ -f "$dockerfile" ]] || fail "Dockerfile not found: $dockerfile"

cat "$dockerfile"

runtime_env_file="$(service_dir "$service")/runtime.env"
if [[ -f "$runtime_env_file" ]]; then
  python3 - "$runtime_env_file" <<'PY'
import sys

lines = []
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"invalid runtime.env line (expected KEY=VALUE): {line}")
        key, value = line.split("=", 1)
        value = value.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'ENV {key.strip()}="{value}"')
if lines:
    print("\n".join(lines))
PY
fi
