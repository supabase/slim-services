# Assembly shared by the three Node applications. The caller has staged app/.
{
  pkgs,
  nodeMajor,
  service,
  command,
}:
let
  inherit (pkgs) lib;
  runtime = import ../portable-node { inherit pkgs nodeMajor; };
  targetOS = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux";
  nodeArch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x64";
in
''
    cp -R ${runtime}/. $out/
    chmod -R u+w $out
    mkdir -p $out/bin
    find $out/app -type f -name 'sentry_cpu_profiler-*.node' \
      ! -name 'sentry_cpu_profiler-${targetOS}-${nodeArch}-*' -delete
    find $out/app -type f \( -name '*-musl-*.node' -o -name '*-musl.node' \) -delete
    find $out/app -type d -path '*/build/Release/obj.target' -prune -exec rm -rf {} +
    find $out/app -type f \( -name '*.o' -o -name '*.o.d' \) -delete
    # npm's build hook patches dependency executables to its build-time Node.
    # Restore portable shebangs before exporting the installed application.
    ${pkgs.python3}/bin/python3 - "$out/app" <<'PY'
  import pathlib, sys
  for path in pathlib.Path(sys.argv[1]).rglob("*"):
      if not path.is_file() or path.is_symlink():
          continue
      with path.open("rb") as stream:
          first = stream.readline(512)
      if first.startswith(b"#!/nix/store/") and b"/bin/node" in first:
          data = path.read_bytes()
          path.write_bytes(b"#!/usr/bin/env node\n" + data.split(b"\n", 1)[1])
  PY
    ${lib.optionalString pkgs.stdenv.isLinux ''
      # Native addons are built against Nix's absolute RUNPATH. Keep their
      # existing relative entries, then point them at the copied Node closure
      # and bundled glibc family from any depth under app/.
      while IFS= read -r elf; do
        [ -n "$elf" ] || continue
        ${pkgs.file}/bin/file "$elf" 2>/dev/null | grep -q "ELF" || continue
        existing_rpath="$(${pkgs.patchelf}/bin/patchelf --print-rpath "$elf" 2>/dev/null || true)"
        preserved_rpath=""
        IFS=: read -r -a rpath_entries <<< "$existing_rpath"
        for rpath in "''${rpath_entries[@]}"; do
          case "$rpath" in
            ""|/nix/store/*) ;;
            *)
              if [ -n "$preserved_rpath" ]; then
                preserved_rpath="$preserved_rpath:$rpath"
              else
                preserved_rpath="$rpath"
              fi
              ;;
          esac
        done
        rel_dylib="$(${pkgs.python3}/bin/python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$out/node/dylib" "$(dirname "$elf")")"
        rel_glibc="$(${pkgs.python3}/bin/python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$out/lib" "$(dirname "$elf")")"
        new_rpath="\$ORIGIN/$rel_dylib:\$ORIGIN/$rel_glibc"
        [ -n "$preserved_rpath" ] && new_rpath="$new_rpath:$preserved_rpath"
        ${pkgs.patchelf}/bin/patchelf --set-rpath "$new_rpath" "$elf"
      done < <(
        find "$out/app" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \) 2>/dev/null
      )
    ''}
    ${lib.optionalString pkgs.stdenv.isDarwin ''
      # Re-run the Darwin closure pass after the application files are staged:
      # native addons may introduce dylibs absent from the standalone Node
      # bundle, but they share its existing dylib directory.
      export PORTABLE_NODE_FILE=${pkgs.file}/bin/file
      export PORTABLE_NODE_PYTHON=${pkgs.python3}/bin/python3
      . ${../portable-node/node-darwin-fixup.sh}
      portable_node_fixup_darwin "$out" "$out/node/dylib"
    ''}
    cat > $out/bin/${service} <<'WRAPPER'
  #!/bin/sh
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  NODE_BIN="''${SUPABASE_NODE:-$SCRIPT_DIR/../node/bin/node}"
  cd "$SCRIPT_DIR/../app"
  exec "$NODE_BIN" ${command} "$@"
  WRAPPER
    chmod 0755 $out/bin/${service}
''
