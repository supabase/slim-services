# Assembly shared by the three Node applications. The caller has staged app/.
{
  pkgs,
  nodeMajor,
  service,
  command,
}:
let
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
    cat > $out/bin/${service} <<'WRAPPER'
  #!/bin/sh
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  NODE_BIN="''${SUPABASE_NODE:-$SCRIPT_DIR/../node/bin/node}"
  cd "$SCRIPT_DIR/../app"
  exec "$NODE_BIN" ${command} "$@"
  WRAPPER
    chmod 0755 $out/bin/${service}
''
