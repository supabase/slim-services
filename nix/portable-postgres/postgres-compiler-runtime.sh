#!/usr/bin/env bash
set -euo pipefail

# Select the real compiler runtime ELF from a pinned stdenv output.  Some
# compiler outputs expose a GNU ld linker script at the SONAME path; copying
# that text file as libstdc++.so.6 makes the bundled loader report "invalid ELF
# header".  Resolve symlinks, reject non-ELFs, and require the target machine
# before copying under the canonical SONAME.

portable_postgres_runtime_arch="${PORTABLE_POSTGRES_RUNTIME_ARCH:-$(uname -m)}"

portable_postgres_runtime_is_elf() {
  file "$1" 2>/dev/null | grep -q "ELF"
}

portable_postgres_runtime_arch_matches() {
  case "$portable_postgres_runtime_arch" in
    aarch64)
      readelf -h "$1" 2>/dev/null | grep -Eq 'Machine:.*AArch64'
      ;;
    x86_64)
      readelf -h "$1" 2>/dev/null | grep -Eq 'Machine:.*(Advanced Micro Devices X86-64|X86-64)'
      ;;
    *)
      echo "portable-postgres: unsupported compiler runtime architecture $portable_postgres_runtime_arch" >&2
      return 1
      ;;
  esac
}

portable_postgres_runtime_find_elf() {
  local runtime_name="$1"
  shift
  local compiler_root candidate
  for compiler_root in "$@"; do
    [ -d "$compiler_root" ] || continue
    while IFS= read -r candidate; do
      [ -f "$candidate" ] || continue
      portable_postgres_runtime_is_elf "$candidate" || continue
      portable_postgres_runtime_arch_matches "$candidate" || continue
      printf '%s\n' "$candidate"
      return 0
    done < <(
      find "$compiler_root" \( -type f -o -type l \) \( -name "$runtime_name" -o -name "$runtime_name.*" \) -print 2>/dev/null \
        | LC_ALL=C sort
    )
  done
  return 1
}

portable_postgres_copy_compiler_runtime() {
  local destination_dir="$1"
  local runtime_name="$2"
  shift 2
  local runtime_file
  runtime_file="$(portable_postgres_runtime_find_elf "$runtime_name" "$@" || true)"
  [ -n "$runtime_file" ] || {
    echo "portable-postgres: no matching ELF $runtime_name found in pinned compiler runtime" >&2
    return 1
  }
  mkdir -p "$destination_dir"
  cp -L "$runtime_file" "$destination_dir/$runtime_name"
  chmod u+w "$destination_dir/$runtime_name"
  portable_postgres_runtime_is_elf "$destination_dir/$runtime_name" || {
    echo "portable-postgres: copied compiler runtime is not an ELF: $runtime_file" >&2
    return 1
  }
  portable_postgres_runtime_arch_matches "$destination_dir/$runtime_name" || {
    echo "portable-postgres: copied compiler runtime has the wrong machine: $runtime_file" >&2
    return 1
  }
}

if [ "${PORTABLE_POSTGRES_COMPILER_RUNTIME_STANDALONE:-0}" = 1 ]; then
  portable_postgres_copy_compiler_runtime \
    "${PORTABLE_POSTGRES_RUNTIME_DEST:?missing PORTABLE_POSTGRES_RUNTIME_DEST}" \
    "${PORTABLE_POSTGRES_RUNTIME_NAME:?missing PORTABLE_POSTGRES_RUNTIME_NAME}" \
    "${PORTABLE_POSTGRES_COMPILER_LIB:?missing PORTABLE_POSTGRES_COMPILER_LIB}" \
    "${PORTABLE_POSTGRES_COMPILER_LIBGCC:?missing PORTABLE_POSTGRES_COMPILER_LIBGCC}"
fi
