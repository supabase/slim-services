#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/beam-release-env.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

env_file="$tmp_dir/env.sh"
cat >"$env_file" <<'EOF'
#!/bin/sh
export RELEASE_DISTRIBUTION=name
export KEEP_ME=present
EOF
chmod 0640 "$env_file"

if mode_before=$(stat -c '%a' "$env_file" 2>/dev/null); then
  :
else
  mode_before=$(stat -f '%Lp' "$env_file")
fi

"$ROOT_DIR/scripts/patch-beam-release-env.sh" "$env_file"

if mode_after=$(stat -c '%a' "$env_file" 2>/dev/null); then
  :
else
  mode_after=$(stat -f '%Lp' "$env_file")
fi
[[ "$mode_after" == "$mode_before" ]]
grep -Fq 'export KEEP_ME=present' "$env_file"

unset RELEASE_DISTRIBUTION
# shellcheck source=/dev/null
source "$env_file"
[[ "$RELEASE_DISTRIBUTION" == name ]]
[[ "$KEEP_ME" == present ]]

RELEASE_DISTRIBUTION=none
# shellcheck source=/dev/null
source "$env_file"
[[ "$RELEASE_DISTRIBUTION" == none ]]

missing_file="$tmp_dir/missing.sh"
printf '%s\n' '#!/bin/sh' 'export KEEP_ME=present' >"$missing_file"
if "$ROOT_DIR/scripts/patch-beam-release-env.sh" "$missing_file" >/dev/null 2>&1; then
  echo "patch unexpectedly succeeded without RELEASE_DISTRIBUTION assignment" >&2
  exit 1
fi

echo "beam release env patch tests passed"
