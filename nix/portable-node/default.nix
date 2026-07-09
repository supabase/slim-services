# Portable Node runtime bundle: the pinned nixpkgs nodejs_24 binary plus its
# non-glibc dylib closure, patched to run from any extraction path on a plain
# host (no /nix/store). Playbook: NIX_PORTABLE_ARTIFACT_PLAYBOOK.md; reference
# implementation: services/pooler/nix/default.nix postFixup.
#
# Self-contained pin — keep in sync with scripts/nixpkgs-pin.sh.
let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/ac62194c3917d5f474c1a844b6fd6da2db95077d.tar.gz";
    sha256 = "0v6bd1xk8a2aal83karlvc853x44dg1n4nk08jg3dajqyy0s98np";
  };
in
{ pkgs ? import nixpkgs { } }:

let
  inherit (pkgs) lib;
  node = pkgs.nodejs_24;
in
pkgs.stdenv.mkDerivation {
  pname = "portable-node";
  version = node.version;

  dontUnpack = true;
  # Stripping and rpath surgery are done by hand below, in the safe order
  # (strip BEFORE patchelf); keep the generic fixups away from the result.
  dontStrip = true;
  dontPatchELF = true;

  nativeBuildInputs = [ pkgs.file pkgs.python3 ]
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf pkgs.binutils ];

  installPhase = ''
    mkdir -p $out/bin
    cp -L ${node}/bin/node $out/bin/node
    chmod u+w $out/bin/node
  '';

  postFixup = lib.optionalString pkgs.stdenv.isLinux ''
    # Linux half of the portable playbook: bundle every non-glibc shared
    # library into dylib/, point every ELF at it with $ORIGIN-relative
    # rpaths and at the host's dynamic loader, then audit with ldd.
    rootfs="$out"
    dylib_dir="$rootfs/dylib"
    mkdir -p "$dylib_dir"

    case "$(uname -m)" in
      aarch64) interp="/lib/ld-linux-aarch64.so.1" ;;
      x86_64) interp="/lib64/ld-linux-x86-64.so.2" ;;
      *) echo "unsupported linux arch $(uname -m)" >&2; exit 1 ;;
    esac

    is_elf() {
      file "$1" 2>/dev/null | grep -q "ELF"
    }

    elf_files() {
      find "$rootfs" -type f \( -perm -0100 -o -name "*.so" -o -name "*.so.*" \) 2>/dev/null \
        | while read -r file_path; do
            if is_elf "$file_path"; then
              echo "$file_path"
            fi
          done
    }

    # The glibc family resolves from the host (contract item 3).
    should_exclude() {
      case "$1" in
        libc.so*|libc-*.so*|ld-linux*.so*|libdl.so*|libpthread.so*|libm.so*|libresolv.so*|librt.so*)
          return 0 ;;
        *)
          return 1 ;;
      esac
    }

    nix_store_deps() {
      ldd "$1" 2>/dev/null | awk '/=> \/nix\/store/ { print $3 } $1 ~ "^/nix/store" { print $1 }'
    }

    # 1. Complete the closure before any patching (ldd still resolves the
    # original Nix rpaths at this point).
    for iteration in 1 2 3 4 5 6 7 8; do
      copied=0
      for elf in $(elf_files) "$dylib_dir"/*; do
        [ -f "$elf" ] || continue
        for dep in $(nix_store_deps "$elf"); do
          dep_name="$(basename "$dep")"
          should_exclude "$dep_name" && continue
          if [ ! -e "$dylib_dir/$dep_name" ] && [ -e "$dep" ]; then
            cp -L "$dep" "$dylib_dir/$dep_name"
            chmod u+w "$dylib_dir/$dep_name"
            copied=1
          fi
        done
      done
      [ "$copied" = "0" ] && break
    done

    # 2. Patch: system loader for executables, $ORIGIN-relative rpath to
    # dylib/ for everything. Strip BEFORE patchelf (GNU strip corrupts
    # patchelf-ed binaries), so run the two passes separately.
    for elf in $(elf_files); do
      strip --strip-unneeded "$elf" 2>/dev/null || true
    done
    for elf in $(elf_files); do
      rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$dylib_dir" "$elf")"
      if patchelf --print-interpreter "$elf" >/dev/null 2>&1; then
        patchelf --set-interpreter "$interp" "$elf" 2>/dev/null || true
      fi
      patchelf --set-rpath "\$ORIGIN/$rel" "$elf" 2>/dev/null || true
    done

    # 3. Audit: no unresolved deps, no Nix store references (the loader
    # itself and the glibc family are expected from the host and resolve
    # to the build sandbox's glibc here).
    echo "Auditing Linux portable output"
    unresolved="$(
      for elf in $(elf_files); do
        ldd "$elf" 2>/dev/null | awk -v file="$elf" -v rootfs="$rootfs" '
          /not found/ { print file " -> " $0; next }
          /=> \// { path = $3 }
          path ~ "^/nix/store/" && index(path, rootfs "/") != 1 {
            name = path
            sub(/^.*\//, "", name)
            if (name !~ /^(ld-linux.*|libc\.so.*|libc-.*\.so.*|libdl\.so.*|libpthread\.so.*|libm\.so.*|libresolv\.so.*|librt\.so.*)$/) {
              print file " -> " path
            }
            path = ""
          }
        '
      done
    )"
    if [ -n "$unresolved" ]; then
      echo "$unresolved" >&2
      exit 1
    fi
  '' + lib.optionalString pkgs.stdenv.isDarwin ''
    rootfs="$out"
    dylib_dir="$rootfs/dylib"
    mkdir -p "$dylib_dir"

    is_macho() {
      file "$1" 2>/dev/null | grep -q "Mach-O"
    }

    macho_files() {
      find "$rootfs" -type f \( -perm -0100 -o -name "*.so" -o -name "*.dylib" -o -name "*.dylib.*" \) 2>/dev/null \
        | while read -r file_path; do
            if is_macho "$file_path"; then
              echo "$file_path"
            fi
          done
    }

    nix_store_deps() {
      otool -L "$1" 2>/dev/null | awk 'NR > 1 && $1 ~ "^/nix/store/" { print $1 }'
    }

    for iteration in 1 2 3 4 5 6 7 8; do
      copied=0
      for macho in $(macho_files); do
        for dep in $(nix_store_deps "$macho"); do
          dep_name="$(basename "$dep")"
          if [ ! -e "$dylib_dir/$dep_name" ] && [ -e "$dep" ]; then
            cp -L "$dep" "$dylib_dir/$dep_name"
            chmod u+w "$dylib_dir/$dep_name"
            copied=1
          fi
        done
      done
      [ "$copied" = "0" ] && break
    done

    for macho in $(macho_files); do
      rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$dylib_dir" "$macho")"

      case "$macho" in
        "$dylib_dir"/*)
          install_name_tool -id "@rpath/$(basename "$macho")" "$macho" 2>/dev/null || true
          ;;
      esac

      changed=0
      for dep in $(nix_store_deps "$macho"); do
        dep_name="$(basename "$dep")"
        if [ -e "$dylib_dir/$dep_name" ]; then
          install_name_tool -change "$dep" "@rpath/$dep_name" "$macho" 2>/dev/null || true
          changed=1
        fi
      done

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
    done

    echo "Auditing Darwin portable output"
    unresolved="$(
      for macho in $(macho_files); do
        otool -L "$macho" 2>/dev/null | awk -v f="$macho" 'NR > 1 && $1 ~ "^/nix/store/" { print f " -> " $1 }'
        otool -l "$macho" 2>/dev/null | awk -v f="$macho" '
          $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
          in_rpath && $1 == "path" && $2 ~ "^/nix/store/" { print f " rpath -> " $2; in_rpath = 0 }
          in_rpath && $1 == "path" { in_rpath = 0 }
        '
      done
    )"
    if [ -n "$unresolved" ]; then
      echo "$unresolved" >&2
      exit 1
    fi

    # NOTE: no textual `grep /nix/store bin/` gate here (unlike a naive reading
    # of the pooler playbook, whose final grep targets shell launch *scripts*).
    # The single artifact is the compiled `node` binary, which embeds inert
    # /nix/store strings in its process.config build metadata (include_dirs,
    # -L flags, its own store path). `strip -x` cannot remove those, and they
    # are not load-time references — the otool audit above is the authoritative
    # portability check (no /nix/store LC_LOAD_DYLIB or LC_RPATH entries). This
    # mirrors the Linux half, which likewise ends at its ldd audit.
  '';
}
