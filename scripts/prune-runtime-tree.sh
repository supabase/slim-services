#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/prune-runtime-tree.sh ROOTFS

Remove non-runtime files from a staged artifact rootfs.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

rootfs="$1"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"

log "pruning non-runtime files under $rootfs"

# Preserve license obligations before pruning documentation. Keep the source
# path below share/licenses so identically named licenses cannot overwrite one
# another and downstream users can trace each notice to its component.
license_root="$rootfs/share/licenses"
mkdir -p "$license_root/slim-services"
cp "$ROOT_DIR/LICENSE" "$license_root/slim-services/LICENSE"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" \
  "$license_root/slim-services/THIRD_PARTY_NOTICES.md"

find "$rootfs" -type f ! -path "$license_root/*" \( \
  -iname 'LICENSE*' -o \
  -iname 'NOTICE*' -o \
  -iname 'COPYING*' -o \
  -iname 'COPYRIGHT*' \
\) -print0 | while IFS= read -r -d '' license_file; do
  relative_path="${license_file#"$rootfs"/}"
  destination="$license_root/$relative_path"
  mkdir -p "$(dirname "$destination")"
  cp -p "$license_file" "$destination"
done

find "$rootfs" -type f \( \
  -name '*.map' -o \
  -name '*.nft.json' -o \
  -name '*.tsbuildinfo' -o \
  -name '*.d.ts' -o \
  -name '*.debug' -o \
  -name '*.a' -o \
  -name '*.la' -o \
  -name '.DS_Store' \
\) -delete

find "$rootfs" -path "$license_root" -prune -o -type d \( \
  -name '.cache' -o \
  -name '.git' -o \
  -name '.github' -o \
  -name '__tests__' -o \
  -name 'test' -o \
  -name 'tests' -o \
  -name 'doc' -o \
  -name 'docs' -o \
  -name 'example' -o \
  -name 'examples' -o \
  -name 'benchmark' -o \
  -name 'benchmarks' \
\) \
  ! -path '*/node_modules/yaml/dist/doc' \
  ! -path '*/node_modules/yaml/browser/dist/doc' \
  -prune -exec rm -rf {} +

find "$rootfs" -type f ! -path "$license_root/*" \( \
  -iname 'README*' -o \
  -iname 'CHANGELOG*' -o \
  -iname 'CONTRIBUTING*' -o \
  -iname 'LICENSE*' -o \
  -iname '*.md' -o \
  -iname '*.markdown' \
\) -delete
