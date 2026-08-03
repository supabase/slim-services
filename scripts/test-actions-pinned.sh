#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/slim-actions-pin-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/.github/workflows"

cat > "$fixture/.github/workflows/good.yml" <<'YAML'
steps:
  - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
  - uses: ./local-action
YAML

ACTIONS_PIN_ROOT="$fixture" "$ROOT_DIR/scripts/check-actions-pinned.sh" >/dev/null

cat > "$fixture/.github/workflows/bad.yml" <<'YAML'
steps:
  - uses: actions/checkout@v4
YAML

if ACTIONS_PIN_ROOT="$fixture" "$ROOT_DIR/scripts/check-actions-pinned.sh" \
  > /dev/null 2>&1; then
  echo "mutable Action tag unexpectedly passed" >&2
  exit 1
fi

echo "Action pin policy test passed"
