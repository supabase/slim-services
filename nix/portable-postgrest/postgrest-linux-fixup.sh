#!/usr/bin/env bash
set -euo pipefail

rootfs="${1:?usage: postgrest-linux-fixup.sh ROOTFS}"
binary="$rootfs/bin/postgrest"
launcher_template="${PORTABLE_POSTGREST_LAUNCHER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/postgrest-launcher.sh}"
license_source="$rootfs/usr/share/doc/libc6/copyright"

[[ -d "$rootfs" ]] || { echo "portable-postgrest: rootfs is not a directory: $rootfs" >&2; exit 1; }
[[ -e "$binary" ]] || { echo "portable-postgrest: binary not found: $binary" >&2; exit 1; }
[[ -x "$launcher_template" ]] || { echo "portable-postgrest: launcher template is missing or not executable: $launcher_template" >&2; exit 1; }
command -v readelf >/dev/null 2>&1 || { echo "portable-postgrest: readelf is required" >&2; exit 1; }

# Ubuntu/Debian images ship the exact glibc package copyright alongside the
# loader copied by AUTO_ELF_DEPS. Preserve it under the artifact license root
# before prune removes /usr/share/doc; old/static images may omit the optional
# package file and continue without it.
if [[ -f "$license_source" ]]; then
  mkdir -p "$rootfs/share/licenses/portable-postgrest"
  cp -p "$license_source" "$rootfs/share/licenses/portable-postgrest/glibc6-copyright"
fi

# Static releases (currently the amd64 path) need no loader or wrapper.  A
# non-ELF fixture is treated the same way, which keeps this seam useful for
# host tests without requiring a target-architecture compiler.
interpreter="$(readelf -lW "$binary" 2>/dev/null \
  | sed -n 's/.*Requesting program interpreter: \(.*\)\].*/\1/p' \
  | head -n 1 || true)"
if [[ -z "$interpreter" ]]; then
  echo "portable-postgrest: static or non-ELF binary, leaving $binary unchanged"
  exit 0
fi
[[ "$interpreter" = /* ]] || { echo "portable-postgrest: unsupported interpreter path: $interpreter" >&2; exit 1; }

loader_name="${interpreter##*/}"
loader="${rootfs}${interpreter}"
if [[ ! -x "$loader" ]]; then
  loader=""
  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then loader="$candidate"; break; fi
  done < <(find "$rootfs" \( -type f -o -type l \) -name "$loader_name" -print 2>/dev/null)
fi
[[ -n "$loader" ]] || { echo "portable-postgrest: bundled loader not found: $loader_name" >&2; exit 1; }
loader_rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$loader" "$rootfs")"

bin_dir="${binary%/*}"
real_name=".postgrest-portable-real"
real="$bin_dir/$real_name"
[[ ! -e "$real" ]] || { echo "portable-postgrest: refusing to overwrite existing real binary: $real" >&2; exit 1; }
mv "$binary" "$real"
root_rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$rootfs" "$bin_dir")"
sed \
  -e "s|@LOADER_NAME@|$loader_name|g" \
  -e "s|@LOADER_REL@|$loader_rel|g" \
  -e "s|@ROOT_REL@|$root_rel|g" \
  -e "s|@REAL_NAME@|$real_name|g" \
  "$launcher_template" > "$binary"
chmod 0755 "$binary"

echo "portable-postgrest: wrapped dynamic binary with bundled $loader_name"
