#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 5 ]]; then
  echo "Usage: scripts/generate-artifact-sbom.sh ROOTFS OUTPUT SERVICE VERSION TARGET" >&2
  exit 2
fi

exec python3 "$ROOT_DIR/scripts/generate-artifact-sbom.py" \
  "$1" "$2" --service "$3" --version "$4" --target "$5"
