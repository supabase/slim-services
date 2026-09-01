#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

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

artifact_rootfs="$tmp_dir/artifact"
mkdir -p "$artifact_rootfs/bin" "$artifact_rootfs/releases/demo"
cat >"$artifact_rootfs/releases/demo/env.sh" <<'EOF'
#!/bin/sh
export RELEASE_DISTRIBUTION=name
EOF
chmod 0755 "$artifact_rootfs/releases/demo/env.sh"
launcher="$artifact_rootfs/bin/demo"
cat >"$launcher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$release_root/releases/demo/env.sh"
[[ "${1:-}" == eval ]] || exit 2
printf '%s\n' "$RELEASE_DISTRIBUTION"
EOF
chmod 0755 "$launcher"

if (smoke_beam_release_distribution "$launcher" >/dev/null 2>&1); then
  echo "distribution smoke unexpectedly passed unpatched artifact" >&2
  exit 1
fi
log "unpatched release env correctly rejected by distribution smoke"

"$ROOT_DIR/scripts/patch-beam-release-env.sh" "$artifact_rootfs/releases/demo/env.sh"
smoke_beam_release_distribution "$launcher"

missing_file="$tmp_dir/missing.sh"
printf '%s\n' '#!/bin/sh' 'export KEEP_ME=present' >"$missing_file"
if "$ROOT_DIR/scripts/patch-beam-release-env.sh" "$missing_file" >/dev/null 2>&1; then
  echo "patch unexpectedly succeeded without RELEASE_DISTRIBUTION assignment" >&2
  exit 1
fi

duplicate_file="$tmp_dir/duplicate.sh"
printf '%s\n' '#!/bin/sh' 'export RELEASE_DISTRIBUTION=name' 'export RELEASE_DISTRIBUTION=name' >"$duplicate_file"
if "$ROOT_DIR/scripts/patch-beam-release-env.sh" "$duplicate_file" >/dev/null 2>&1; then
  echo "patch unexpectedly succeeded with duplicate RELEASE_DISTRIBUTION assignments" >&2
  exit 1
fi

bare_file="$tmp_dir/bare.sh"
printf '%s\n' '#!/bin/sh' 'RELEASE_DISTRIBUTION=name' >"$bare_file"
if "$ROOT_DIR/scripts/patch-beam-release-env.sh" "$bare_file" >/dev/null 2>&1; then
  echo "patch unexpectedly accepted a bare RELEASE_DISTRIBUTION assignment" >&2
  exit 1
fi

echo "beam release env patch tests passed"
