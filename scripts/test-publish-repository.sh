#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/slim-publish-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"

cat > "$fixture/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "repo" && "$2" == "view" ]]; then
  echo INTERNAL
  exit 0
fi
printf '%s\n' "$*" >> "$MOCK_GH_LOG"
MOCK
chmod +x "$fixture/bin/gh"

export MOCK_GH_LOG="$fixture/mutations.log"
export PATH="$fixture/bin:$PATH"

"$ROOT_DIR/scripts/publish-repository.sh" --repository example/project \
  > "$fixture/dry-run.log"
test ! -e "$MOCK_GH_LOG"
grep -q 'Dry run only' "$fixture/dry-run.log"

if "$ROOT_DIR/scripts/publish-repository.sh" \
  --repository example/project --execute --confirm-public wrong/project \
  > /dev/null 2>&1; then
  echo "mismatched publication confirmation unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$MOCK_GH_LOG"

if "$ROOT_DIR/scripts/publish-repository.sh" \
  --repository example/project --execute --confirm-public example/project \
  > /dev/null 2>&1; then
  echo "publication without human approvals unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$MOCK_GH_LOG"

echo "repository publication safeguards passed"
