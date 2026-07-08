#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/audit-portable-artifact.sh --darwin ROOTFS
  scripts/audit-portable-artifact.sh --linux ROOTFS

Fail if a portable artifact still has unresolved or host-specific runtime deps.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

mode="$1"
rootfs="$2"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"

# Symlinks must stay relative on every platform: an absolute target (a Nix
# store leak, or any host path) breaks the moment the artifact is extracted
# somewhere else. Relative links are also what the dedup pass in portable
# packaging emits, so this doubles as its regression check.
bad_symlinks="$(
  find "$rootfs" -type l 2>/dev/null \
    | while IFS= read -r link_path; do
        target="$(readlink "$link_path")"
        case "$target" in
          /*) printf '%s -> %s\n' "$link_path" "$target" ;;
        esac
      done
)"
if [[ -n "$bad_symlinks" ]]; then
  printf '%s\n' "$bad_symlinks" >&2
  fail "artifact contains absolute symlinks (not relocatable)"
fi

case "$mode" in
  --darwin)
    require_cmd file
    require_cmd otool
    require_cmd codesign
    unresolved="$(
      find "$rootfs" -type f 2>/dev/null \
        | while IFS= read -r file_path; do
            if file "$file_path" | grep -q 'Mach-O'; then
              # An invalid signature means macOS SIGKILLs the process that
              # loads the file — an in-sandbox codesign shim can produce
              # these on special dylibs (reexport stubs).
              if ! codesign --verify "$file_path" >/dev/null 2>&1; then
                printf '%s -> invalid code signature\n' "$file_path"
              fi
              # /nix/store: build machine leak. /opt/homebrew + /usr/local:
              # package-manager paths not guaranteed on user machines.
              otool -L "$file_path" 2>/dev/null \
                | awk -v file="$file_path" 'NR > 1 && ($1 ~ "^/nix/store/" || $1 ~ "^/opt/homebrew/" || $1 ~ "^/usr/local/") { print file " -> " $1 }'
              otool -l "$file_path" 2>/dev/null \
                | awk -v file="$file_path" '
                    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
                    in_rpath && $1 == "path" && $2 ~ "^/nix/store/" { print file " rpath -> " $2; in_rpath = 0 }
                    in_rpath && $1 == "path" { in_rpath = 0 }
                  '
            fi
          done
    )"
    if [[ -n "$unresolved" ]]; then
      printf '%s\n' "$unresolved" >&2
      fail "Darwin artifact contains absolute Nix store references"
    fi
    ;;
  --linux)
    require_cmd file
    require_cmd ldd
    require_cmd readelf
    # Resolve against the artifact's own library dirs first (including Debian
    # multiarch dirs) so bundled libs don't get checked against older host
    # copies of the same soname.
    lib_path="$rootfs/usr/local/lib:$rootfs/lib:$rootfs/usr/lib"
    for dir in "$rootfs"/lib/*-linux-gnu* "$rootfs"/usr/lib/*-linux-gnu*; do
      [[ -d "$dir" ]] && lib_path="$lib_path:$dir"
    done
    unresolved="$(
      find "$rootfs" -type f 2>/dev/null \
        | while IFS= read -r file_path; do
            if file "$file_path" | grep -q 'ELF'; then
              # ldd exits nonzero on statically linked binaries; that is a
              # pass, not an audit error, so keep pipefail from killing the
              # scan. (No apostrophes here: bash 3.2 on macOS mis-parses
              # quotes in comments inside command substitutions.)
              LD_LIBRARY_PATH="$lib_path:${LD_LIBRARY_PATH:-}" \
                ldd "$file_path" 2>/dev/null \
                | awk -v file="$file_path" '/not found/ { print file " -> " $0 }' \
                || true
              # Absolute store paths in NEEDED/RPATH RESOLVE on a build
              # machine (its /nix/store exists), so the ldd pass above cannot
              # catch them — reject the strings themselves. (Real leak seen:
              # nixpkgs proj/gdal carry an absolute NEEDED for libsqlite3.)
              readelf -d "$file_path" 2>/dev/null \
                | awk -v file="$file_path" '/NEEDED|RUNPATH|RPATH/ && /\/nix\/store\// { print file " -> " $0 }' \
                || true
            fi
          done
    )"
    if [[ -n "$unresolved" ]]; then
      printf '%s\n' "$unresolved" >&2
      fail "Linux artifact has unresolved shared-library dependencies"
    fi
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

log "portable artifact audit passed: $mode $rootfs"
