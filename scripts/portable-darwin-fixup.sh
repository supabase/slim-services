#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/portable-darwin-fixup.sh ROOTFS

Complete and optimize a macOS portable runtime tree:
- copy missing @rpath and absolute /nix/store dylib dependencies into lib/;
- rewrite copied Nix store install names to @rpath;
- remove absolute /nix/store rpaths;
- strip local symbols;
- ad-hoc sign mutated Mach-O files;
- audit that no shipped Mach-O references /nix/store.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

rootfs="$1"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"
[[ -d "$rootfs/lib" ]] || fail "Darwin portable rootfs must contain lib/: $rootfs"

require_cmd file
require_cmd find
require_cmd otool
require_cmd install_name_tool
require_cmd strip
require_cmd codesign

find_macho_files() {
  find "$rootfs/bin" "$rootfs/lib" -type f 2>/dev/null \
    | while IFS= read -r file_path; do
        if file "$file_path" | grep -q 'Mach-O'; then
          printf '%s\n' "$file_path"
        fi
      done
}

read_rpaths() {
  local macho="$1"
  otool -l "$macho" 2>/dev/null \
    | awk '
        $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
        in_rpath && $1 == "path" { print $2; in_rpath = 0 }
      '
}

log "completing Darwin dylib closure under $rootfs"
for _iteration in 1 2 3 4 5; do
  copy_marker="$rootfs/.darwin-deps-copied"
  rm -f "$copy_marker"

  while IFS= read -r macho; do
    rpaths=()
    while IFS= read -r rpath; do
      rpaths+=("$rpath")
    done < <(read_rpaths "$macho")

    while IFS= read -r dep; do
      dep_name="$(basename "$dep")"
      [[ -e "$rootfs/lib/$dep_name" ]] && continue

      candidate=""
      for rpath in "${rpaths[@]}"; do
        case "$rpath" in
          @loader_path) maybe="$(dirname "$macho")/$dep_name" ;;
          @executable_path/../lib) maybe="$rootfs/lib/$dep_name" ;;
          /nix/store/*) maybe="$rpath/$dep_name" ;;
          *) maybe="" ;;
        esac
        if [[ -n "$maybe" && -e "$maybe" ]]; then
          candidate="$maybe"
          break
        fi
      done

      if [[ -z "$candidate" ]]; then
        candidate="$(find /nix/store -path "*/lib/$dep_name" -type f -print -quit 2>/dev/null || true)"
      fi

      if [[ -n "$candidate" && -e "$candidate" ]]; then
        cp -P "$candidate" "$rootfs/lib/$dep_name"
        chmod u+w "$rootfs/lib/$dep_name" 2>/dev/null || true
        touch "$copy_marker"
      fi
    done < <(otool -L "$macho" 2>/dev/null | awk 'NR > 1 && $1 ~ "^@rpath/" { print $1 }')

    while IFS= read -r dep; do
      dep_name="$(basename "$dep")"
      [[ -e "$rootfs/lib/$dep_name" ]] && continue
      if [[ -e "$dep" ]]; then
        cp -P "$dep" "$rootfs/lib/$dep_name"
        chmod u+w "$rootfs/lib/$dep_name" 2>/dev/null || true
        touch "$copy_marker"
      fi
    done < <(otool -L "$macho" 2>/dev/null | awk 'NR > 1 && $1 ~ "^/nix/store/" { print $1 }')
  done < <(find_macho_files)

  [[ ! -f "$copy_marker" ]] && break
done
rm -f "$rootfs/.darwin-deps-copied"

log "patching and stripping Darwin Mach-O files under $rootfs"
while IFS= read -r macho; do
  case "$macho" in
    "$rootfs/lib/"*)
      install_name_tool -id "@rpath/$(basename "$macho")" "$macho" 2>/dev/null || true
      ;;
  esac

  while IFS= read -r dep; do
    dep_name="$(basename "$dep")"
    if [[ -e "$rootfs/lib/$dep_name" ]]; then
      install_name_tool -change "$dep" "@rpath/$dep_name" "$macho" 2>/dev/null || true
    fi
  done < <(otool -L "$macho" 2>/dev/null | awk 'NR > 1 && $1 ~ "^/nix/store/" { print $1 }')

  while IFS= read -r rpath; do
    case "$rpath" in
      /nix/store/*) install_name_tool -delete_rpath "$rpath" "$macho" 2>/dev/null || true ;;
    esac
  done < <(read_rpaths "$macho")

  strip -x "$macho" 2>/dev/null || true
  codesign --force --sign - "$macho" >/dev/null 2>&1 || true
done < <(find_macho_files)

"$ROOT_DIR/scripts/audit-portable-artifact.sh" --darwin "$rootfs"
