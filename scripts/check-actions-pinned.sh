#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ACTIONS_PIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
failures=0

while IFS=: read -r file line content; do
  reference="$(printf '%s\n' "$content" | sed -E 's/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^['"'"'\"]//; s/['"'"'\"]$//')"
  if [[ "$reference" == ./* ]]; then
    continue
  fi
  if [[ ! "$reference" =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]]; then
    printf '%s:%s: external action is not pinned to a full commit SHA: %s\n' \
      "$file" "$line" "$reference" >&2
    failures=1
  fi
done < <(grep -R -n -E '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*' "$ROOT_DIR/.github/workflows" --include='*.yml' --include='*.yaml')

[[ "$failures" == "0" ]] || exit 1
echo "all external Actions are pinned to full commit SHAs"
