#!/usr/bin/env bash
set -euo pipefail

# Shared Linux fixup for the portable PostgreSQL package. The caller supplies
# all pinned Nix inputs through environment variables so this script can be
# host-tested independently from the upstream source tree.
rootfs="${PORTABLE_POSTGRES_ROOTFS:?missing PORTABLE_POSTGRES_ROOTFS}"
glibc_source="${PORTABLE_POSTGRES_GLIBC_LIB:?missing PORTABLE_POSTGRES_GLIBC_LIB}"
glibc_root="${PORTABLE_POSTGRES_GLIBC_ROOT:-${glibc_source%/lib}}"
locale_source="${PORTABLE_POSTGRES_LOCALE_LIB:?missing PORTABLE_POSTGRES_LOCALE_LIB}"
compiler_lib="${PORTABLE_POSTGRES_COMPILER_LIB:?missing PORTABLE_POSTGRES_COMPILER_LIB}"
compiler_libgcc="${PORTABLE_POSTGRES_COMPILER_LIBGCC:?missing PORTABLE_POSTGRES_COMPILER_LIBGCC}"
compiler_src="${PORTABLE_POSTGRES_COMPILER_SRC:?missing PORTABLE_POSTGRES_COMPILER_SRC}"
launcher_template="${PORTABLE_POSTGRES_LAUNCHER:?missing PORTABLE_POSTGRES_LAUNCHER}"
entrypoint_helper="${PORTABLE_POSTGRES_ENTRYPOINT_HELPER:?missing PORTABLE_POSTGRES_ENTRYPOINT_HELPER}"

# Keep hidden-entrypoint normalization and launcher generation in one
# executable seam so host tests can exercise the exact public-name contract.
. "$entrypoint_helper"

runtime_dir="$rootfs/lib"
mkdir -p "$runtime_dir"

case "$(uname -m)" in
  aarch64) interp="/lib/ld-linux-aarch64.so.1"; loader_name="ld-linux-aarch64.so.1" ;;
  x86_64) interp="/lib64/ld-linux-x86-64.so.2"; loader_name="ld-linux-x86-64.so.2" ;;
  *) echo "unsupported linux arch $(uname -m)" >&2; exit 1 ;;
esac

# Copy one matching loader and its complete glibc family from the same pinned
# package. These files are deliberately never stripped or patchelf-ed.
cp -L "$glibc_source/$loader_name" "$runtime_dir/$loader_name"
for pattern in \
  "libc.so.6" "libc-*.so.*" "libm.so.6" "libm-*.so.*" \
  "libmvec.so.1" "libmvec-*.so.*" "libdl.so.2" "libdl-*.so.*" \
  "libpthread.so.0" "libpthread-*.so.*" "libresolv.so.2" "libresolv-*.so.*" \
  "librt.so.1" "librt-*.so.*" "libutil.so.1" "libutil-*.so.*" \
  "libanl.so.1" "libanl-*.so.*" "libBrokenLocale.so.1" "libBrokenLocale-*.so.*" \
  "libthread_db.so.1" "libthread_db-*.so.*" "libnss_*.so" "libnss_*.so.*" \
  "libnsl.so.1" "libnsl-*.so.*"
do
  for glibc_file in "$glibc_source"/$pattern; do
    [ -e "$glibc_file" ] || continue
    cp -L "$glibc_file" "$runtime_dir/${glibc_file##*/}"
  done
done

if [ -d "$glibc_source/gconv" ]; then
  mkdir -p "$runtime_dir/gconv"
  cp -RL "$glibc_source/gconv/." "$runtime_dir/gconv/"
fi
if [ -d "$locale_source" ]; then
  mkdir -p "$runtime_dir/locale"
  cp -RL "$locale_source/." "$runtime_dir/locale/"
fi

# Keep exact license texts for manually staged runtime inputs. The source
# archives are derivation inputs from the pinned nixpkgs, so this is fail-loud
# and traceable rather than relying on an unpinned host path.
copy_source_notice() {
  source_archive="$1"
  notice_name="$2"
  destination="$3"
  notice_member=""
  # Consume the complete tar listing: exiting awk on the first match sends
  # SIGPIPE to tar under the derivation's pipefail shell.
  notice_member="$(tar -tf "$source_archive" | awk -v suffix="/$notice_name" '
    length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix && first == "" {
      first = $0
    }
    END { if (first != "") print first }
  ')"
  [ -n "$notice_member" ] || {
    echo "missing $notice_name in pinned source archive $source_archive" >&2
    exit 1
  }
  mkdir -p "$(dirname "$destination")"
  tar -xOf "$source_archive" "$notice_member" > "$destination"
}

license_dir="$rootfs/share/licenses/portable-postgres"
mkdir -p "$license_dir"
copy_source_notice "${PORTABLE_POSTGRES_GLIBC_SRC:-$glibc_root/src}" COPYING.LIB "$license_dir/glibc-COPYING.LIB"
copy_source_notice "$compiler_src" COPYING.RUNTIME "$license_dir/gcc-COPYING.RUNTIME"
copy_source_notice "$compiler_src" COPYING3 "$license_dir/gcc-COPYING3"
cat > "$license_dir/components.txt" <<EOF
Pinned glibc ${PORTABLE_POSTGRES_GLIBC_VERSION:-unknown}: glibc-COPYING.LIB
Pinned GCC runtime ${PORTABLE_POSTGRES_COMPILER_VERSION:-unknown}: gcc-COPYING.RUNTIME and gcc-COPYING3
EOF

# Native extensions may require C++ ABI/runtime libraries even when the core
# PostgreSQL executable does not. Seed both compiler outputs before closure
# discovery so the final loader audit also covers extension ELFs.
copy_compiler_runtime() {
  runtime_name="$1"
  runtime_file=""
  for compiler_root in "$compiler_lib" "$compiler_libgcc"; do
    [ -d "$compiler_root" ] || continue
    runtime_file="$(find "$compiler_root" -type f \( -name "$runtime_name" -o -name "$runtime_name.*" \) -print -quit 2>/dev/null || true)"
    [ -n "$runtime_file" ] && break
  done
  [ -n "$runtime_file" ] || {
    echo "missing pinned compiler runtime $runtime_name under $compiler_lib" >&2
    exit 1
  }
  cp -L "$runtime_file" "$runtime_dir/$runtime_name"
  chmod u+w "$runtime_dir/$runtime_name"
}
copy_compiler_runtime "libstdc++.so.6"
copy_compiler_runtime "libgcc_s.so.1"

is_elf() {
  portable_postgres_is_elf "$1"
}

# buildPhase stages the upstream-resolved binaries under hidden
# `.NAME-wrapped` names so Darwin can keep its existing wrapper phase. Linux
# normalizes those ELF paths back to their public command names before the
# generic PT_INTERP pass below; otherwise the launcher would be installed only
# at the hidden path and `postgres`, `psql`, etc. would disappear.
portable_postgres_normalize_hidden_entrypoints "$rootfs"

elf_files() {
  find "$rootfs" -type f -print 2>/dev/null \
    | while IFS= read -r file_path; do
        is_elf "$file_path" && printf '%s\n' "$file_path"
      done
}

# Restrict this predicate to the directly copied glibc family and side data;
# libstdc++, extensions, and any nested shared objects remain auditable users.
is_bundled_glibc() {
  case "$1" in
    "$runtime_dir"/ld-linux*|"$runtime_dir"/libc.so*|"$runtime_dir"/libc-*|\
    "$runtime_dir"/libm.so*|"$runtime_dir"/libm-*|"$runtime_dir"/libmvec.so*|\
    "$runtime_dir"/libmvec-*|"$runtime_dir"/libdl.so*|"$runtime_dir"/libdl-*|\
    "$runtime_dir"/libpthread.so*|"$runtime_dir"/libpthread-*|\
    "$runtime_dir"/libresolv.so*|"$runtime_dir"/libresolv-*|\
    "$runtime_dir"/librt.so*|"$runtime_dir"/librt-*|"$runtime_dir"/libutil.so*|\
    "$runtime_dir"/libutil-*|"$runtime_dir"/libanl.so*|"$runtime_dir"/libanl-*|\
    "$runtime_dir"/libBrokenLocale.so*|"$runtime_dir"/libBrokenLocale-*|\
    "$runtime_dir"/libthread_db.so*|"$runtime_dir"/libthread_db-*|\
    "$runtime_dir"/libnss_*|"$runtime_dir"/libnsl.so.1|"$runtime_dir"/libnsl-*.so.*|\
    "$runtime_dir"/gconv/*|"$runtime_dir"/locale/*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

should_exclude() {
  case "$1" in
    libc.so*|libc-*.so*|ld-linux*.so*|libdl.so*|libpthread.so*|libm.so*|\
    libresolv.so*|librt.so*|libutil.so*|libanl.so*|libBrokenLocale.so*|\
    libthread_db.so*|libnss_*.so*|libnsl.so.1|libnsl-*.so.*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

nix_store_deps() {
  ldd "$1" 2>/dev/null \
    | awk '/=> \/nix\/store/ { print $3 } $1 ~ "^/nix/store" { print $1 }'
}

copy_store_notices() {
  dependency="$1"
  case "$dependency" in
    /nix/store/*/*)
      store_name="${dependency#/nix/store/}"
      store_name="${store_name%%/*}"
      destination="$rootfs/share/licenses/$store_name"
      mkdir -p "$destination"
      while IFS= read -r notice; do
        [ -f "$notice" ] || continue
        cp -p "$notice" "$destination/${notice##*/}"
      done <<EOF
$(find "/nix/store/$store_name" -maxdepth 4 -type f \( -iname '*copying*' -o -iname '*license*' -o -iname '*notice*' \) -print 2>/dev/null)
EOF
      ;;
  esac
}

# Complete the non-glibc closure while original Nix rpaths still resolve.
for iteration in 1 2 3 4 5 6 7 8; do
  copied=0
  while IFS= read -r elf; do
    [ -n "$elf" ] || continue
    is_bundled_glibc "$elf" && continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      dep_name="${dep##*/}"
      should_exclude "$dep_name" && continue
      if [ ! -e "$runtime_dir/$dep_name" ] && [ -e "$dep" ]; then
        cp -L "$dep" "$runtime_dir/$dep_name"
        chmod u+w "$runtime_dir/$dep_name"
        copy_store_notices "$dep"
        copied=1
      fi
    done <<EOF
$(nix_store_deps "$elf")
EOF
  done <<EOF
$(elf_files)
EOF
  [ "$copied" = 0 ] && break
done

# Record executable entrypoints before replacing them with wrappers. Shared
# objects/extensions have no PT_INTERP and are intentionally left untouched.
entrypoints_file="$rootfs/.portable-postgres-entrypoints"
: > "$entrypoints_file"
while IFS= read -r elf; do
  [ -n "$elf" ] || continue
  is_bundled_glibc "$elf" && continue
  [ -x "$elf" ] || continue
  readelf -l "$elf" 2>/dev/null | grep -q 'INTERP' || continue
  printf '%s\n' "$elf" >> "$entrypoints_file"
done <<EOF
$(elf_files)
EOF

# Strip and relocate only non-glibc ELFs. The pinned glibc bytes above stay
# exactly as supplied by nixpkgs.
while IFS= read -r elf; do
  [ -n "$elf" ] || continue
  is_bundled_glibc "$elf" && continue
  strip --strip-unneeded "$elf" 2>/dev/null || true
done <<EOF
$(elf_files)
EOF
while IFS= read -r elf; do
  [ -n "$elf" ] || continue
  is_bundled_glibc "$elf" && continue
  rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$runtime_dir" "$elf")"
  if patchelf --print-interpreter "$elf" >/dev/null 2>&1; then
    patchelf --set-interpreter "$interp" "$elf" 2>/dev/null || true
  fi
  patchelf --set-rpath "\$ORIGIN/$rel" "$elf" 2>/dev/null || true
done <<EOF
$(elf_files)
EOF

# Rewrite absolute Nix-store NEEDED entries (not only files in lib/; native
# extensions under share/postgresql/extension may carry them too).
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  while IFS= read -r elf; do
    [ -n "$elf" ] || continue
    is_bundled_glibc "$elf" && continue
    for needed in $(patchelf --print-needed "$elf" 2>/dev/null || true); do
      case "$needed" in
        /nix/store/*)
          base="${needed##*/}"
          if [ ! -e "$runtime_dir/$base" ] && [ -e "$needed" ]; then
            cp -L "$needed" "$runtime_dir/$base"
            chmod u+w "$runtime_dir/$base"
            copy_store_notices "$needed"
            strip --strip-unneeded "$runtime_dir/$base" 2>/dev/null || true
            patchelf --set-rpath "\$ORIGIN" "$runtime_dir/$base" 2>/dev/null || true
            changed=1
          fi
          [ -e "$runtime_dir/$base" ] || {
            echo "absolute Nix dependency is unavailable: $elf -> $needed" >&2
            exit 1
          }
          patchelf --replace-needed "$needed" "$base" "$elf" 2>/dev/null || true
          ;;
      esac
    done
  done <<EOF
$(elf_files)
EOF
done

argv0_supported=0
if "$runtime_dir/$loader_name" --help 2>&1 | grep -q -- '--argv0'; then
  argv0_supported=1
fi

# Install the same relative-loader launcher at every public PostgreSQL binary.
portable_postgres_install_entrypoint_wrappers \
  "$rootfs" "$launcher_template" "$loader_name" "$argv0_supported" \
  "$entrypoints_file"
rm -f "$entrypoints_file"

# Audit every non-glibc ELF with the exact bundled loader/library path used by
# generated wrappers. Host ldd is not the final proof for a bundled artifact.
echo "Auditing Linux portable PostgreSQL output"
while IFS= read -r elf; do
  [ -n "$elf" ] || continue
  is_bundled_glibc "$elf" && continue
  loader_output=""
  if ! loader_output="$(
    "$runtime_dir/$loader_name" \
      --library-path "$runtime_dir" \
      --list "$elf" 2>&1
  )"; then
    echo "$elf -> bundled loader audit failed: $loader_output" >&2
    exit 1
  fi
  if printf '%s\n' "$loader_output" | grep -q 'not found'; then
    echo "$elf -> bundled loader reported unresolved dependency: $loader_output" >&2
    exit 1
  fi
  outside_store="$(printf '%s\n' "$loader_output" | awk -v file="$elf" -v rootfs="$rootfs" '
    {
      for (field_index = 1; field_index <= NF; field_index++) {
        path = $field_index
        sub(/\(.*$/, "", path)
        if (path ~ /^\/nix\/store\// && index(path, rootfs "/") != 1) print file " -> " path
      }
    }
  ')"
  [ -z "$outside_store" ] || { echo "$outside_store" >&2; exit 1; }
done <<EOF
$(elf_files)
EOF
