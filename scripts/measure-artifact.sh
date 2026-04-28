#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/measure-artifact.sh ROOTFS [ARCHIVE] [IMAGE]

Report rootfs size, optional archive size, and optional Docker image size.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 3 ]] || { usage >&2; exit 2; }

rootfs="$1"
archive="${2:-}"
image="${3:-}"

[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"

rootfs_kib="$(du -sk "$rootfs" | awk '{print $1}')"
awk -v kib="$rootfs_kib" 'BEGIN { printf "rootfs_mib=%.1f\n", kib / 1024 }'

if [[ -n "$archive" && -f "$archive" ]]; then
  archive_bytes="$(wc -c < "$archive" | tr -d ' ')"
  awk -v bytes="$archive_bytes" 'BEGIN { printf "archive_mib=%.1f\n", bytes / 1024 / 1024 }'
fi

if [[ -n "$image" ]]; then
  require_cmd docker
  image_bytes="$(docker image inspect "$image" --format '{{.Size}}')"
  awk -v bytes="$image_bytes" 'BEGIN { printf "image_mib=%.1f\n", bytes / 1024 / 1024 }'
fi
