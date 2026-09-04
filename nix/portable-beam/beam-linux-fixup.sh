# shellcheck shell=sh
# Shared Linux fixup for the BEAM-family portable packages. The caller sets
# the source paths below from the same pinned package set before evaluating
# this file; keeping the algorithm here avoids three drifting copies.
rootfs="${PORTABLE_BEAM_ROOTFS:?missing PORTABLE_BEAM_ROOTFS}"
glibc_source="${PORTABLE_BEAM_GLIBC_LIB:?missing PORTABLE_BEAM_GLIBC_LIB}"
glibc_source_archive="${PORTABLE_BEAM_GLIBC_SRC:?missing PORTABLE_BEAM_GLIBC_SRC}"
compiler_source_archive="${PORTABLE_BEAM_COMPILER_SRC:?missing PORTABLE_BEAM_COMPILER_SRC}"
tzdata_source="${PORTABLE_BEAM_TZDATA:?missing PORTABLE_BEAM_TZDATA}"
tzdata_source_archive="${PORTABLE_BEAM_TZDATA_SRC:?missing PORTABLE_BEAM_TZDATA_SRC}"
locale_source="${PORTABLE_BEAM_LOCALE_LIB:?missing PORTABLE_BEAM_LOCALE_LIB}"
launcher_template="${PORTABLE_BEAM_LAUNCHER:?missing PORTABLE_BEAM_LAUNCHER}"
dylib_dir="$rootfs/dylib"
glibc_dir="$rootfs/lib"
mkdir -p "$dylib_dir" "$glibc_dir"

case "$(uname -m)" in
  aarch64) interp="/lib/ld-linux-aarch64.so.1"; loader_name="ld-linux-aarch64.so.1" ;;
  x86_64) interp="/lib64/ld-linux-x86-64.so.2"; loader_name="ld-linux-x86-64.so.2" ;;
  *) echo "unsupported linux arch $(uname -m)" >&2; exit 1 ;;
esac

# Copy one matching loader and its complete glibc family from the same pinned
# package. These files are intentionally never stripped or patchelf-ed.
cp -L "$glibc_source/$loader_name" "$glibc_dir/$loader_name"
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
    cp -L "$glibc_file" "$glibc_dir/${glibc_file##*/}"
  done
done
if [ -d "$glibc_source/gconv" ]; then
  mkdir -p "$glibc_dir/gconv"
  cp -RL "$glibc_source/gconv/." "$glibc_dir/gconv/"
fi
if [ -d "$locale_source" ]; then
  mkdir -p "$glibc_dir/locale"
  cp -RL "$locale_source/." "$glibc_dir/locale/"
fi

# Keep exact license text for each manually staged runtime input. Source
# archives are pinned derivation inputs; fail loudly if a required notice is
# absent instead of silently shipping an empty license directory.
license_dir="$rootfs/share/licenses/portable-beam"
mkdir -p "$license_dir"
copy_source_notice() {
  source_archive="$1"
  notice_name="$2"
  destination="$3"
  notice_member="$(tar -tf "$source_archive" | awk -v notice="$notice_name" -v suffix="/$notice_name" '
    selected == "" && ($0 == notice || (length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix)) {
      selected = $0
    }
    END { if (selected != "") print selected }
  ')"
  [ -n "$notice_member" ] || {
    echo "portable-beam: missing $notice_name in pinned source archive $source_archive" >&2
    exit 1
  }
  tar -xOf "$source_archive" "$notice_member" > "$destination"
}
copy_source_notice "$glibc_source_archive" COPYING.LIB "$license_dir/glibc-COPYING.LIB"
copy_source_notice "$compiler_source_archive" COPYING.RUNTIME "$license_dir/gcc-COPYING.RUNTIME"
copy_source_notice "$compiler_source_archive" COPYING3 "$license_dir/gcc-COPYING3"
copy_source_notice "$tzdata_source_archive" LICENSE "$license_dir/tzdata-LICENSE"
cat > "$license_dir/components.txt" <<EOF
Pinned glibc source: glibc-COPYING.LIB
Pinned compiler runtime source: gcc-COPYING.RUNTIME and gcc-COPYING3
Pinned tzdata source: tzdata-LICENSE
EOF

# Runtime side data: minimal hosts may lack zoneinfo. Keep user TZDIR values
# authoritative while making the pinned data available to release env.sh.
mkdir -p "$rootfs/share"
cp -RL "$tzdata_source" "$rootfs/share/zoneinfo"
chmod -R u+w "$rootfs/share/zoneinfo"
rm -rf "$rootfs/share/zoneinfo/posix" "$rootfs/share/zoneinfo/right"
for envsh in "$rootfs"/releases/*/env.sh; do
  [ -f "$envsh" ] || continue
  {
    printf '\n## Portable artifact: prefer bundled zoneinfo (see nix package)\n'
    printf 'if [ -z "${TZDIR:-}" ] && [ -d "$RELEASE_ROOT/share/zoneinfo" ]; then\n'
    printf '  export TZDIR="$RELEASE_ROOT/share/zoneinfo"\nfi\n'
  } >> "$envsh"
done

is_elf() {
  file "$1" 2>/dev/null | grep -q "ELF"
}

elf_files() {
  find "$rootfs" -type f -print 2>/dev/null \
    | while IFS= read -r file_path; do
        if is_elf "$file_path"; then
          printf '%s\n' "$file_path"
        fi
      done
}

# glibc files are copied into the release's existing top-level lib/ directory.
# Restrict this predicate to direct files and side-data children so nested
# BEAM app/NIF ELFs below lib/ remain part of the closure.
is_bundled_glibc() {
  case "$1" in
    "$glibc_dir"/ld-linux*|"$glibc_dir"/libc.so*|"$glibc_dir"/libc-*|\
    "$glibc_dir"/libm.so*|"$glibc_dir"/libm-*|"$glibc_dir"/libmvec.so*|\
    "$glibc_dir"/libmvec-*|"$glibc_dir"/libdl.so*|"$glibc_dir"/libdl-*|\
    "$glibc_dir"/libpthread.so*|"$glibc_dir"/libpthread-*|\
    "$glibc_dir"/libresolv.so*|"$glibc_dir"/libresolv-*|\
    "$glibc_dir"/librt.so*|"$glibc_dir"/librt-*|"$glibc_dir"/libutil.so*|\
    "$glibc_dir"/libutil-*|"$glibc_dir"/libanl.so*|"$glibc_dir"/libanl-*|\
    "$glibc_dir"/libBrokenLocale.so*|"$glibc_dir"/libBrokenLocale-*|\
    "$glibc_dir"/libthread_db.so*|"$glibc_dir"/libthread_db-*|\
    "$glibc_dir"/libnss_*|"$glibc_dir"/libnsl.so*|"$glibc_dir"/libnsl-*|\
    "$glibc_dir"/gconv/*|\
    "$glibc_dir"/locale/*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

nix_store_deps() {
  ldd "$1" 2>/dev/null \
    | awk '/=> \/nix\/store/ { print $3 } $1 ~ "^/nix/store" { print $1 }'
}

should_exclude() {
  case "$1" in
    libc.so*|libc-*.so*|ld-linux*.so*|libdl.so*|libpthread.so*|libm.so*|libmvec.so*|\
    libresolv.so*|librt.so*|libutil.so*|libanl.so*|libBrokenLocale.so*|\
    libthread_db.so*|libnss_*.so*|libnsl.so*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

copy_store_notices() {
  dependency="$1"
  case "$dependency" in
    /nix/store/*/*)
      store_name="${dependency#/nix/store/}"
      store_name="${store_name%%/*}"
      source_root="/nix/store/$store_name"
      destination="$rootfs/share/licenses/$store_name"
      [ -d "$source_root" ] || return 0
      # Most Nix outputs carry their notice files under share/doc or at the
      # output root. Preserve those texts when available; unlike the pinned
      # runtime archives above, a dependency output may legitimately omit a
      # license file, so closure discovery remains fail-closed on linkage.
      while IFS= read -r notice; do
        [ -f "$notice" ] || continue
        mkdir -p "$destination"
        cp -p "$notice" "$destination/${notice##*/}"
      done <<EOF
$(find "$source_root" -maxdepth 4 -type f \( -iname '*copying*' -o -iname '*license*' -o -iname '*notice*' \) -print 2>/dev/null)
EOF
      ;;
  esac
}

# Complete the non-glibc closure while original Nix rpaths still resolve.
for _ in 1 2 3 4 5 6 7 8; do
  copied=0
  while IFS= read -r elf; do
    [ -n "$elf" ] || continue
    is_bundled_glibc "$elf" && continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      dep_name="${dep##*/}"
      should_exclude "$dep_name" && continue
      if [ ! -e "$dylib_dir/$dep_name" ] && [ -e "$dep" ]; then
        cp -L "$dep" "$dylib_dir/$dep_name"
        chmod u+w "$dylib_dir/$dep_name"
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

# Capture dynamic executable entrypoints before replacing them with wrappers.
# PT_INTERP is the behavior-based discriminator: shared objects/NIFs do not
# carry it, regardless of ERTS or service version.
entrypoints_file="$rootfs/.portable-beam-entrypoints"
: > "$entrypoints_file"
while IFS= read -r elf; do
  [ -n "$elf" ] || continue
  is_bundled_glibc "$elf" && continue
  [ -x "$elf" ] || continue
  if readelf -l "$elf" 2>/dev/null | grep -q 'INTERP'; then
    printf '%s\n' "$elf" >> "$entrypoints_file"
  fi
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
  rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$dylib_dir" "$elf")"
  if patchelf --print-interpreter "$elf" >/dev/null 2>&1; then
    patchelf --set-interpreter "$interp" "$elf" 2>/dev/null || true
  fi
  patchelf --set-rpath "\$ORIGIN/$rel" "$elf" 2>/dev/null || true
done <<EOF
$(elf_files)
EOF

argv0_supported=0
if "$glibc_dir/$loader_name" --help 2>&1 | grep -q -- '--argv0'; then
  argv0_supported=1
fi

# Install the same generic launcher at every ERTS executable/port path.
while IFS= read -r elf; do
  [ -n "$elf" ] || continue
  bin_dir="${elf%/*}"
  public_name="${elf##*/}"
  real_name=".${public_name}-portable-real"
  real_path="$bin_dir/$real_name"
  [ ! -e "$real_path" ] || {
    echo "portable-beam: refusing to overwrite existing real executable: $real_path" >&2
    exit 1
  }
  mv "$elf" "$real_path"
  root_rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$rootfs" "$bin_dir")"
  sed \
    -e "s|@LOADER_NAME@|$loader_name|g" \
    -e "s|@ROOT_REL@|$root_rel|g" \
    -e "s|@REAL_NAME@|$real_name|g" \
    -e "s|@ARGV0_SUPPORTED@|$argv0_supported|g" \
    "$launcher_template" > "$elf"
  chmod 0755 "$elf"
done < "$entrypoints_file"
rm -f "$entrypoints_file"

# Audit every non-glibc ELF with the exact bundled loader/libc pair used by
# generated launchers. Host ldd is intentionally not used as final proof.
echo "Auditing Linux portable BEAM output"
while IFS= read -r elf; do
  [ -n "$elf" ] || continue
  is_bundled_glibc "$elf" && continue
  loader_output=""
  if ! loader_output="$(
    "$glibc_dir/$loader_name" \
      --library-path "$glibc_dir:$dylib_dir" \
      --list "$elf" 2>&1
  )"; then
    echo "$elf -> bundled loader audit failed: $loader_output" >&2
    exit 1
  fi
  if printf '%s\n' "$loader_output" | grep -q 'not found'; then
    echo "$elf -> bundled loader reported unresolved dependency: $loader_output" >&2
    exit 1
  fi
  outside_store="$(
    printf '%s\n' "$loader_output" |
      awk -v file="$elf" -v rootfs="$rootfs" '
        {
          for (field_index = 1; field_index <= NF; field_index++) {
            path = $field_index
            sub(/\(.*$/, "", path)
            if (path ~ /^\/nix\/store\// && index(path, rootfs "/") != 1) {
              print file " -> " path
            }
          }
        }
      '
  )"
  if [ -n "$outside_store" ]; then
    echo "$outside_store" >&2
    exit 1
  fi
done <<EOF
$(elf_files)
EOF
