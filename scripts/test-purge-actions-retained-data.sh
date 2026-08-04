#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/slim-actions-purge-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"

cat > "$fixture/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "repo" && "$2" == "view" ]]; then
  echo INTERNAL
  exit 0
fi

if [[ "$1" == "api" && "$*" == *"--method DELETE"* ]]; then
  printf '%s\n' "$*" >> "$MOCK_GH_LOG"
  exit 0
fi

if [[ "$1" == "api" && "$*" == *"--paginate"* && "$*" == *"actions/runs"* ]]; then
  printf '101\n102\n'
  exit 0
fi

if [[ "$1" == "api" && "$*" == *"--paginate"* && "$*" == *"actions/artifacts"* ]]; then
  printf '201\n'
  exit 0
fi

if [[ "$1" == "api" && "$*" == *"actions/runs?per_page=1"* ]]; then
  [[ -s "$MOCK_GH_LOG" ]] && echo 0 || echo 2
  exit 0
fi

if [[ "$1" == "api" && "$*" == *"actions/artifacts?per_page=1"* ]]; then
  [[ -s "$MOCK_GH_LOG" ]] && echo 0 || echo 3
  exit 0
fi

echo "unexpected mock gh invocation: $*" >&2
exit 1
MOCK
chmod +x "$fixture/bin/gh"

export MOCK_GH_LOG="$fixture/deletes.log"
export PATH="$fixture/bin:$PATH"

"$ROOT_DIR/scripts/purge-actions-retained-data.sh" --repository example/project \
  > "$fixture/dry-run.log"
test ! -e "$MOCK_GH_LOG"
grep -q 'Dry run only' "$fixture/dry-run.log"

if "$ROOT_DIR/scripts/purge-actions-retained-data.sh" \
  --repository example/project --execute --confirm-delete-all wrong/project \
  > /dev/null 2>&1; then
  echo "mismatched confirmation unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$MOCK_GH_LOG"

"$ROOT_DIR/scripts/purge-actions-retained-data.sh" \
  --repository example/project --execute \
  --confirm-delete-all example/project > "$fixture/execute.log"

test "$(wc -l < "$MOCK_GH_LOG" | tr -d ' ')" == "3"
grep -q 'actions/runs/101' "$MOCK_GH_LOG"
grep -q 'actions/runs/102' "$MOCK_GH_LOG"
grep -q 'actions/artifacts/201' "$MOCK_GH_LOG"
grep -q 'all retained Actions data deleted' "$fixture/execute.log"

echo "Actions retained-data purge safeguards passed"
