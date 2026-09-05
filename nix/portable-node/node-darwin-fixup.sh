#!/usr/bin/env bash

# Relocate Mach-O dependencies into a portable dylib directory.
#
# The function is intentionally sourced by both the standalone Node bundle and
# each application bundle. The second invocation sees the same Node closure plus
# application native addons, so newly discovered addon dependencies join the
# existing closure and use the same @loader_path layout.

portable_node_fixup_darwin() {
  local rootfs="$1"
  local dylib_dir="$2"
  local file_tool="${PORTABLE_NODE_FILE:-file}"
  local python_tool="${PORTABLE_NODE_PYTHON:-python3}"

  mkdir -p "$dylib_dir"

  portable_node_is_macho() {
    "$file_tool" "$1" 2>/dev/null | grep -q "Mach-O"
  }

  portable_node_macho_files() {
    find "$rootfs" -type f \( \
      -perm -0100 -o \
      -name "*.so" -o \
      -name "*.dylib" -o \
      -name "*.dylib.*" -o \
      -name "*.node" \
    \) 2>/dev/null \
      | while read -r file_path; do
          if portable_node_is_macho "$file_path"; then
            echo "$file_path"
          fi
        done
  }

  portable_node_nix_store_deps() {
    otool -L "$1" 2>/dev/null | awk 'NR > 1 && $1 ~ "^/nix/store/" { print $1 }'
  }

  # Complete the closure before changing install names. This keeps otool able
  # to resolve the original Nix paths while each new dependency is discovered.
  for iteration in 1 2 3 4 5 6 7 8; do
    : "$iteration"
    local copied=0
    while read -r macho; do
      [ -n "$macho" ] || continue
      while read -r dep; do
        [ -n "$dep" ] || continue
        local dep_name
        dep_name="$(basename "$dep")"
        if [ ! -e "$dylib_dir/$dep_name" ] && [ -e "$dep" ]; then
          cp -L "$dep" "$dylib_dir/$dep_name"
          chmod u+w "$dylib_dir/$dep_name"
          copied=1
        fi
      done < <(portable_node_nix_store_deps "$macho")
    done < <(portable_node_macho_files)
    [ "$copied" = "0" ] && break
  done

  while read -r macho; do
    [ -n "$macho" ] || continue
    local rel
    rel="$("$python_tool" -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$dylib_dir" "$macho")"

    case "$macho" in
      "$dylib_dir"/*)
        install_name_tool -id "@rpath/$(basename "$macho")" "$macho" 2>/dev/null || true
        ;;
    esac

    local changed=0
    while read -r dep; do
      [ -n "$dep" ] || continue
      local dep_name
      dep_name="$(basename "$dep")"
      if [ -e "$dylib_dir/$dep_name" ]; then
        install_name_tool -change "$dep" "@rpath/$dep_name" "$macho" 2>/dev/null || true
        changed=1
      fi
    done < <(portable_node_nix_store_deps "$macho")

    if [ "$changed" = "1" ]; then
      install_name_tool -add_rpath "@loader_path/$rel" "$macho" 2>/dev/null || true
    fi

    otool -l "$macho" 2>/dev/null | awk '
      $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
      in_rpath && $1 == "path" { print $2; in_rpath = 0 }
    ' | while read -r rpath; do
      case "$rpath" in
        /nix/store/*) install_name_tool -delete_rpath "$rpath" "$macho" 2>/dev/null || true ;;
      esac
    done

    strip -x "$macho" 2>/dev/null || true
    codesign --force --sign - "$macho" 2>/dev/null || true
  done < <(portable_node_macho_files)

  echo "Auditing Darwin portable output at $rootfs"
  local unresolved
  unresolved="$(
    while read -r macho; do
      [ -n "$macho" ] || continue
      otool -L "$macho" 2>/dev/null | awk -v f="$macho" 'NR > 1 && $1 ~ "^/nix/store/" { print f " -> " $1 }'
      otool -l "$macho" 2>/dev/null | awk -v f="$macho" '
        $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
        in_rpath && $1 == "path" && $2 ~ "^/nix/store/" { print f " rpath -> " $2; in_rpath = 0 }
        in_rpath && $1 == "path" { in_rpath = 0 }
      '
    done < <(portable_node_macho_files)
  )"
  if [ -n "$unresolved" ]; then
    echo "$unresolved" >&2
    return 1
  fi
}
