#!/usr/bin/env bash
set -euo pipefail

# Shared entrypoint seam for the Linux PostgreSQL fixup.  The upstream Nix
# derivation first stages public commands as hidden `.NAME-wrapped` files so
# Darwin can retain its existing wrappers.  Linux turns those files into
# public loader launchers while preserving each ELF as a hidden real file.

portable_postgres_is_elf() {
  file "$1" 2>/dev/null | grep -q "ELF"
}

portable_postgres_normalize_hidden_entrypoints() {
  local rootfs="$1"
  local hidden public_name public_path
  for hidden in "$rootfs"/bin/.*-wrapped; do
    [ -f "$hidden" ] || continue
    portable_postgres_is_elf "$hidden" || continue
    public_name="${hidden##*/}"
    public_name="${public_name#.}"
    public_name="${public_name%-wrapped}"
    public_path="$rootfs/bin/$public_name"
    [ ! -e "$public_path" ] || {
      echo "portable-postgres: refusing to overwrite public executable: $public_path" >&2
      return 1
    }
    mv "$hidden" "$public_path"
  done
}

portable_postgres_install_entrypoint_wrappers() {
  local rootfs="$1"
  local launcher_template="$2"
  local loader_name="$3"
  local argv0_supported="$4"
  local entrypoints_file="${5:-}"
  local entrypoints_tmp=""
  local elf bin_dir public_name real_name real_path root_rel

  if [ -z "$entrypoints_file" ]; then
    entrypoints_tmp="$rootfs/.portable-postgres-entrypoints"
    entrypoints_file="$entrypoints_tmp"
    : > "$entrypoints_file"
    while IFS= read -r elf; do
      [ -n "$elf" ] || continue
      portable_postgres_is_elf "$elf" || continue
      [ -x "$elf" ] || continue
      readelf -l "$elf" 2>/dev/null | grep -q 'INTERP' || continue
      printf '%s\n' "$elf" >> "$entrypoints_file"
    done < <(find "$rootfs" -type f -print 2>/dev/null)
  fi

  while IFS= read -r elf; do
    [ -n "$elf" ] || continue
    bin_dir="${elf%/*}"
    public_name="${elf##*/}"
    real_name=".${public_name}-portable-real"
    real_path="$bin_dir/$real_name"
    [ ! -e "$real_path" ] || {
      echo "portable-postgres: refusing to overwrite existing real executable: $real_path" >&2
      return 1
    }
    mv "$elf" "$real_path"
    root_rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$rootfs" "$bin_dir")"
    sed \
      -e "s|@LOADER_NAME@|$loader_name|g" \
      -e "s|@ROOT_REL@|$root_rel|g" \
      -e "s|@REAL_NAME@|$real_name|g" \
      -e "s|@ARGV0_SUPPORTED@|$argv0_supported|g" \
      "$launcher_template" > "$elf"
    chmod 0755 "$elf"
  done < "$entrypoints_file"

  [ -z "$entrypoints_tmp" ] || rm -f "$entrypoints_tmp"
}

if [ "${PORTABLE_POSTGRES_ENTRYPOINT_STANDALONE:-0}" = 1 ]; then
  portable_postgres_rootfs="${PORTABLE_POSTGRES_ROOTFS:?missing PORTABLE_POSTGRES_ROOTFS}"
  portable_postgres_launcher="${PORTABLE_POSTGRES_LAUNCHER:?missing PORTABLE_POSTGRES_LAUNCHER}"
  portable_postgres_loader="${PORTABLE_POSTGRES_LOADER_NAME:?missing PORTABLE_POSTGRES_LOADER_NAME}"
  portable_postgres_argv0="${PORTABLE_POSTGRES_ARGV0_SUPPORTED:-0}"
  portable_postgres_normalize_hidden_entrypoints "$portable_postgres_rootfs"
  portable_postgres_install_entrypoint_wrappers \
    "$portable_postgres_rootfs" "$portable_postgres_launcher" \
    "$portable_postgres_loader" "$portable_postgres_argv0"
fi
