#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: services/studio/validate-artifact.sh ROOTFS
       services/studio/validate-artifact.sh ROOTFS MANIFEST

Validate Studio's assembled runtime layout, every symlink it emits, and (when
provided) the manifest's published commands.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

rootfs="$1"
manifest="${2:-}"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"
require_cmd python3

symlink_errors=""
if ! symlink_errors="$(python3 "$ROOT_DIR/scripts/validate-artifact-symlinks.py" "$rootfs" 2>&1)"; then
  printf '%s\n' "$symlink_errors" >&2
  fail "Studio artifact contains invalid symlinks"
fi

if [[ -n "$manifest" ]]; then
  [[ -f "$manifest" ]] || fail "Studio artifact manifest not found: $manifest"
  python3 - "$rootfs" "$manifest" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
manifest_path = pathlib.Path(sys.argv[2])
try:
    with manifest_path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"Studio artifact manifest cannot be read: {error}")

expected_commands = {
    "entrypoint": ["/slim-runtime/bin/studio"],
    "cmd": ["/node/bin/node", "apps/studio/server.js"],
}

for name, expected in expected_commands.items():
    command = manifest.get(name)
    if not isinstance(command, list) or command != expected:
        raise SystemExit(f"manifest {name} mismatch: expected {expected}")
    for value in expected:
        if value.startswith("/slim-runtime/"):
            candidate = root / value.removeprefix("/slim-runtime/")
        elif value.startswith("/"):
            candidate = root / value.lstrip("/")
        else:
            candidate = root / "app" / value
        try:
            resolved = candidate.resolve(strict=True)
        except FileNotFoundError:
            raise SystemExit(f"manifest {name} target missing: {value}")
        except (OSError, RuntimeError) as error:
            raise SystemExit(f"manifest {name} target cannot resolve: {value} ({error})")
        try:
            resolved.relative_to(root)
        except ValueError:
            raise SystemExit(f"manifest {name} target outside artifact root: {value}")
        if not resolved.is_file():
            raise SystemExit(f"manifest {name} target is not a regular file: {value}")
PY
fi

required_executables=(
  "bin/studio"
  "node/bin/node"
)
for relative_path in "${required_executables[@]}"; do
  [[ -f "$rootfs/$relative_path" ]] || fail "Studio artifact missing required runtime path: $relative_path"
  [[ -x "$rootfs/$relative_path" ]] || fail "Studio artifact runtime path must be executable: $relative_path"
done

required_files=(
  "app/apps/studio/docker-entrypoint.mjs"
  "app/apps/studio/server.js"
)
for relative_path in "${required_files[@]}"; do
  [[ -f "$rootfs/$relative_path" ]] || fail "Studio artifact missing required runtime path: $relative_path"
done

log "Studio artifact boundary validation passed: $rootfs"
