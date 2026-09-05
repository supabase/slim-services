# Portable Node runtime bundle: the upstream-selected Node major from pinned
# nixpkgs plus its
# non-glibc dylib closure, patched to run from any extraction path on a plain
# host (no /nix/store). Playbook: NIX_PORTABLE_ARTIFACT_PLAYBOOK.md; reference
# implementation: services/pooler/nix/default.nix postFixup.
#
{ pkgs, nodeMajor }:

let
  inherit (pkgs) lib;
  resolvedNodeMajor = toString nodeMajor;
  nodeAttribute = "nodejs_${resolvedNodeMajor}";
  node =
    if builtins.hasAttr nodeAttribute pkgs then
      builtins.getAttr nodeAttribute pkgs
    else
      throw "pinned nixpkgs does not provide ${nodeAttribute} required by upstream";
  # Native service addons may require the C++ ABI runtime even though Node
  # itself does not. Resolve both compiler outputs from the pinned stdenv;
  # never reach for a host library path.
  compilerRuntimeLib = lib.getLib pkgs.stdenv.cc.cc;
  compilerRuntimeLibgcc =
    if pkgs.stdenv.cc.cc ? libgcc then pkgs.stdenv.cc.cc.libgcc else compilerRuntimeLib;
  # Node's ICU supplies application locale data, but keep the small glibc
  # archive used by existing service probes when the pinned package exposes it.
  # Restrict it to en_US.UTF-8 rather than pulling nixpkgs' all-locales output.
  glibcLocalesMinimal = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [ "en_US.UTF-8/UTF-8" ];
  };
in
pkgs.stdenv.mkDerivation {
  pname = "portable-node";
  version = node.version;

  dontUnpack = true;
  # Stripping and rpath surgery are done by hand below, in the safe order
  # (strip BEFORE patchelf); keep the generic fixups away from the result.
  dontStrip = true;
  dontPatchELF = true;

  nativeBuildInputs = [
    pkgs.file
    pkgs.python3
  ]
  ++ lib.optionals pkgs.stdenv.isLinux [
    pkgs.patchelf
    pkgs.binutils
  ];

  installPhase = ''
    # Keep the runtime under a node/ subtree so consumers can copy it to the
    # public /node path. Linux postFixup adds the matching glibc family at the
    # staged output root; host build consumers copy that directory to the
    # artifact rootfs alongside node/.
    mkdir -p $out/node/bin
    cp -L ${node}/bin/node $out/node/bin/node
    chmod u+w $out/node/bin/node
  '';

  postFixup =
    lib.optionalString pkgs.stdenv.isLinux ''
          # Linux half of the portable playbook: bundle every non-glibc shared
          # library into node/dylib/, copy one matching glibc family plus loader to
          # lib/, point every ELF at it with $ORIGIN-relative rpaths, then audit.
          rootfs="$out"
          node_root="$rootfs/node"
          dylib_dir="$node_root/dylib"
          glibc_dir="$rootfs/lib"
          mkdir -p "$dylib_dir"
          mkdir -p "$glibc_dir"

          case "$(uname -m)" in
            aarch64) interp="/lib/ld-linux-aarch64.so.1"; loader_name="ld-linux-aarch64.so.1" ;;
            x86_64) interp="/lib64/ld-linux-x86-64.so.2"; loader_name="ld-linux-x86-64.so.2" ;;
            *) echo "unsupported linux arch $(uname -m)" >&2; exit 1 ;;
          esac

          # The Node ELF is entered through this exact loader, rather than through a
          # host loader selected by the kernel. Keep the loader and its paired libc
          # family in the top-level lib/ layout accepted by audit-portable-artifact.
          glibc_lib="${pkgs.glibc}/lib"
          cp -L "$glibc_lib/$loader_name" "$glibc_dir/$loader_name"
          for pattern in \
            "libc.so.6" "libc-*.so.*" "libm.so.6" "libm-*.so.*" \
            "libmvec.so.1" "libmvec-*.so.*" "libdl.so.2" "libdl-*.so.*" \
            "libpthread.so.0" "libpthread-*.so.*" "libresolv.so.2" "libresolv-*.so.*" \
            "librt.so.1" "librt-*.so.*" "libutil.so.1" "libutil-*.so.*" \
            "libanl.so.1" "libanl-*.so.*" "libBrokenLocale.so.1" "libBrokenLocale-*.so.*" \
            "libthread_db.so.1" "libthread_db-*.so.*" "libnss_*.so.*" \
            "libnsl.so.1" "libnsl-*.so.*"
          do
            for glibc_file in "$glibc_lib"/$pattern; do
              [ -e "$glibc_file" ] || continue
              cp -L "$glibc_file" "$glibc_dir/$(basename "$glibc_file")"
            done
          done
          if [ -d "$glibc_lib/gconv" ]; then
            cp -RL "$glibc_lib/gconv" "$glibc_dir/gconv"
          fi
          if [ -d "${glibcLocalesMinimal}/lib/locale" ]; then
            mkdir -p "$glibc_dir/locale"
            cp -RL "${glibcLocalesMinimal}/lib/locale/." "$glibc_dir/locale/"
          fi

          # Keep the exact license texts for the pinned glibc and compiler runtime
          # sources alongside their copied objects. The archive contract requires
          # notices under share/licenses, and these source archives are already
          # derivation inputs (no host filesystem or unpinned download is used).
          license_dir="$rootfs/share/licenses/portable-node"
          mkdir -p "$license_dir"
          bash ${./copy-source-notice.sh} "${pkgs.glibc.src}" COPYING.LIB "$license_dir/glibc-COPYING.LIB"
          bash ${./copy-source-notice.sh} "${pkgs.stdenv.cc.cc.src}" COPYING.RUNTIME "$license_dir/gcc-COPYING.RUNTIME"
          bash ${./copy-source-notice.sh} "${pkgs.stdenv.cc.cc.src}" COPYING3 "$license_dir/gcc-COPYING3"
          cat > "$license_dir/components.txt" <<EOF
      Pinned glibc ${pkgs.glibc.version}: glibc-COPYING.LIB
      Pinned GCC runtime ${pkgs.stdenv.cc.cc.version}: gcc-COPYING.RUNTIME and gcc-COPYING3
      EOF

          # Native addons staged by service builds use these compiler runtime
          # libraries (for example Sentry's CPU profiler). Seed their SONAME names
          # before closure discovery so the final bundled-loader audit covers them.
          # Select compiler runtimes by real ELF type and target machine. Some
          # stdenv outputs expose linker scripts at SONAME paths, which cannot be
          # loaded by the bundled glibc runtime.
          export PORTABLE_NODE_RUNTIME_ARCH="$(uname -m)"
          . ${./node-compiler-runtime.sh}
          portable_node_copy_compiler_runtime \
            "$dylib_dir" "libstdc++.so.6" \
            "${compilerRuntimeLib}" "${compilerRuntimeLibgcc}"
          portable_node_copy_compiler_runtime \
            "$dylib_dir" "libgcc_s.so.1" \
            "${compilerRuntimeLib}" "${compilerRuntimeLibgcc}"

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

          # Keep the complete glibc family in the staged rootfs. The wrapper invokes
          # this exact loader/libc pair, so Node never mixes host and bundled glibc.
          should_exclude() {
            case "$1" in
              libc.so*|libc-*.so*|ld-linux*.so*|libdl.so*|libpthread.so*|libm.so*|libresolv.so*|librt.so*|libutil.so*|libanl.so*|libBrokenLocale.so*|libthread_db.so*|libnss_*.so*|libnsl.so*)
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
              case "$elf" in "$glibc_dir"/*) continue ;; esac
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

          # 2. Patch: the real Node ELF keeps the standard interpreter metadata for
          # audit/readelf, while the launcher invokes the bundled loader directly.
          # Every non-glibc ELF gets an $ORIGIN-relative rpath to the closure.
          # Bundled glibc objects stay byte-for-byte from the pinned package. Strip
          # BEFORE patchelf (GNU strip corrupts patchelf-ed binaries).
          for elf in $(elf_files); do
            case "$elf" in "$glibc_dir"/*) continue ;; esac
            strip --strip-unneeded "$elf" 2>/dev/null || true
          done
          for elf in $(elf_files); do
            case "$elf" in "$glibc_dir"/*) continue ;; esac
            rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$dylib_dir" "$elf")"
            if patchelf --print-interpreter "$elf" >/dev/null 2>&1; then
              patchelf --set-interpreter "$interp" "$elf" 2>/dev/null || true
            fi
            patchelf --set-rpath "\$ORIGIN/$rel" "$elf" 2>/dev/null || true
          done

          # Replace the copied Node ELF with the exact relative-loader launcher.
          # The templates are repo-owned and installed verbatim so host-only tests
          # exercise the same files that enter the Nix output.
          mv "$node_root/bin/node" "$node_root/bin/.node-real"
          sed "s|@LOADER_NAME@|$loader_name|g" ${./node-launcher.sh} > "$node_root/bin/node"
          cp ${./node-execpath.cjs} "$node_root/bin/.node-execpath.cjs"
          chmod 0755 "$node_root/bin/node"
          chmod 0644 "$node_root/bin/.node-execpath.cjs"

          # 3. Audit the non-glibc closure with the exact loader/libc pair that the
          # launcher uses. Bundled glibc objects are intentionally omitted: running
          # host ldd against a different glibc provenance is misleading. Any
          # unresolved dependency, loader failure, or fallback into another Nix
          # store path must fail the derivation before it can be exported.
          echo "Auditing Linux portable output"
          for elf in $(elf_files); do
            case "$elf" in "$glibc_dir"/*) continue ;; esac
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
          done
    ''
    + lib.optionalString pkgs.stdenv.isDarwin ''
      rootfs="$out/node"
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
