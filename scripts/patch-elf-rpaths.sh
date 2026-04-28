#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/patch-elf-rpaths.sh ROOTFS

Patch Linux ELF rpaths with patchelf:
- files under */lib/* get $ORIGIN
- other ELF files get $ORIGIN/../lib:$ORIGIN/lib:$ORIGIN
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

require_cmd file
require_cmd patchelf

rootfs="$1"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"

while IFS= read -r -d '' path; do
  file "$path" | grep -q 'ELF' || continue
  case "$path" in
    */lib/*)
      patchelf --set-rpath '$ORIGIN' "$path" 2>/dev/null || true
      ;;
    *)
      patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN/lib:$ORIGIN' "$path" 2>/dev/null || true
      ;;
  esac
done < <(find "$rootfs" -type f -print0)

log "rpath patching complete: $rootfs"
