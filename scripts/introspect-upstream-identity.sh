#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/identity-lib.sh
source "$ROOT_DIR/scripts/identity-lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/introspect-upstream-identity.sh SERVICE [OUTDIR]

Pull the digest-pinned upstream image and write identity.env into OUTDIR
(default: a temp directory; path printed on stdout).

SOURCE_IMAGE_DIGEST is required. SKIP_UPSTREAM_IDENTITY=1 is rejected
(it would invent uid/gid/mode).
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

service="$1"
outdir="${2:-}"

load_recipe "$service"
identity_service "$service" || fail "$service is not an identity-contract service"
if [[ "${SKIP_UPSTREAM_IDENTITY:-}" == "1" ]]; then
  fail "SKIP_UPSTREAM_IDENTITY=1 is rejected (it would invent uid/gid/mode)"
fi

if [[ -z "$outdir" ]]; then
  outdir="$(mktemp -d "${TMPDIR:-/tmp}/slim-identity.XXXXXX")"
fi

write_upstream_identity "$service" "$outdir"
printf '%s\n' "$outdir"
