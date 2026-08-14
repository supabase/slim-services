#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/resolve-external-release.sh DESCRIPTOR VERSION OUTPUT [SOURCE_LOCK_SCRIPT]

Resolve one manually selected external release into a deterministic immutable
snapshot and write OUTPUT.sha256 over its exact bytes.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -lt 3 || $# -gt 4 ]]; then
  usage >&2
  exit 2
fi

exec python3 "$ROOT_DIR/scripts/external-release.py" "$@"
