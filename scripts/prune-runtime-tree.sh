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

find "$rootfs" -type d \( \
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

find "$rootfs" -type f \( \
  -iname 'README*' -o \
  -iname 'CHANGELOG*' -o \
  -iname 'CONTRIBUTING*' -o \
  -iname 'LICENSE*' -o \
  -iname '*.md' -o \
  -iname '*.markdown' \
\) -delete
