#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/smoke-lib.sh
source "$ROOT_DIR/scripts/smoke-lib.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/beam-release-env.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

artifact_rootfs="$tmp_dir/artifact"
mkdir -p "$artifact_rootfs/bin" "$artifact_rootfs/releases/demo"
env_file="$artifact_rootfs/releases/demo/env.sh"
cat >"$env_file" <<'EOF'
#!/bin/sh
export RELEASE_DISTRIBUTION=name
EOF
chmod 0755 "$env_file"

launcher="$artifact_rootfs/bin/demo"
cat >"$launcher" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$release_root/releases/demo/env.sh"
[[ "${1:-}" == eval ]] || exit 2
[[ "${SMOKE_MARKER:-}" == present ]] || exit 3
printf '%s\n' 'release runtime noise'
case "${SMOKE_OUTPUT_MODE:-normal}" in
  missing) exit 0 ;;
  wrong) printf '__slim_beam_release_distribution__=wrong\n' ;;
  normal) printf '__slim_beam_release_distribution__=%s\n' "$RELEASE_DISTRIBUTION" ;;
  *) exit 4 ;;
esac
EOF
chmod 0755 "$launcher"

if (smoke_beam_release_distribution "$launcher" \
  SMOKE_MARKER=present RELEASE_DISTRIBUTION=caller >/dev/null 2>&1); then
  echo "distribution smoke unexpectedly passed unpatched artifact" >&2
  exit 1
fi
log "unpatched release env correctly rejected by distribution smoke"

cat >"$env_file" <<'EOF'
#!/bin/sh
export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-name}"
EOF
smoke_beam_release_distribution "$launcher" \
  SMOKE_MARKER=present RELEASE_DISTRIBUTION=caller

if (smoke_beam_release_distribution "$launcher" \
  SMOKE_MARKER=present SMOKE_OUTPUT_MODE=missing >/dev/null 2>&1); then
  echo "distribution smoke unexpectedly accepted a missing marker" >&2
  exit 1
fi
if (smoke_beam_release_distribution "$launcher" \
  SMOKE_MARKER=present SMOKE_OUTPUT_MODE=wrong >/dev/null 2>&1); then
  echo "distribution smoke unexpectedly accepted a wrong marker value" >&2
  exit 1
fi

echo "beam release env behavior tests passed"
