#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/collect-elf-deps.sh ROOTFS DEST_LIB_DIR ELF_PATH...

Recursively crawl Linux ELF shared-library dependencies with ldd and copy them
into DEST_LIB_DIR. Run this inside a Linux builder/container that can execute
ldd for the target architecture.

ELF_PATH may be absolute inside ROOTFS, or an existing host/container path.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 3 ]] || { usage >&2; exit 2; }

require_cmd ldd
require_cmd file

rootfs="$1"
dest_lib_dir="$2"
shift 2

[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"
mkdir -p "$dest_lib_dir"

resolve_path() {
  local path="$1"
  if [[ "$path" = /* && -e "$rootfs$path" ]]; then
    printf '%s\n' "$rootfs$path"
  elif [[ -e "$path" ]]; then
    printf '%s\n' "$path"
  else
    return 1
  fi
}

copy_dep() {
  local dep="$1"
  local src base dst
  src="$(resolve_path "$dep")" || return 0
  base="$(basename "$src")"
  dst="$dest_lib_dir/$base"
  if [[ ! -e "$dst" ]]; then
    cp -L "$src" "$dst"
    chmod 0644 "$dst" || true
    printf '%s\n' "$dst"
  fi
}

extract_ldd_paths() {
  local item="$1"
  ldd "$item" 2>/dev/null | awk '
    /=> \// { print $3; next }
    /^[[:space:]]*\// { print $1; next }
  '
}

queue=()
seen_file="$(mktemp)"
trap 'rm -f "$seen_file"' EXIT

for input in "$@"; do
  resolved="$(resolve_path "$input")" || fail "ELF path not found: $input"
  queue+=("$resolved")
done

while ((${#queue[@]} > 0)); do
  item="${queue[0]}"
  queue=("${queue[@]:1}")

  if grep -Fxq "$item" "$seen_file"; then
    continue
  fi
  printf '%s\n' "$item" >> "$seen_file"

  if ! file "$item" | grep -q 'ELF'; then
    continue
  fi

  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    copied="$(copy_dep "$dep" || true)"
    [[ -n "${copied:-}" ]] && queue+=("$copied")
  done < <(extract_ldd_paths "$item" || true)
done

log "ELF dependency collection complete: $dest_lib_dir"
