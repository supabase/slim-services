# Darwin uses the exact upstream release binary and a pinned portable libpq.
{
  pkgs,
  version,
  assetUrl,
  assetHash,
}:
let
  runtime = pkgs.stdenv.mkDerivation {
    pname = "postgrest-portable";
    inherit version;
    src = pkgs.fetchurl {
      url = assetUrl;
      hash = assetHash;
    };
    sourceRoot = ".";
    dontBuild = true;
    dontFixup = true;
    nativeBuildInputs = [
      pkgs.file
      pkgs.python3
      pkgs.darwin.sigtool
    ];
    installPhase = ''
      mkdir -p $out/bin $out/lib
      install -m 0755 postgrest $out/bin/postgrest
      cp -L ${pkgs.libpq}/lib/libpq.5*.dylib $out/lib/libpq.5.dylib
      chmod u+w $out/lib/libpq.5.dylib
      otool -L $out/bin/postgrest \
        | awk 'NR > 1 && ($1 ~ "^/opt/homebrew/" || $1 ~ "^/usr/local/") { print $1 }' \
        | while IFS= read -r dep; do
          install_name_tool -change "$dep" "@rpath/$(basename "$dep")" $out/bin/postgrest
        done
      install_name_tool -add_rpath '@executable_path/../lib' $out/bin/postgrest
      # Upstream's macOS binary picks up its CI runner's default deployment
      # target: v16.2-v16.5 ship minos 14.0, v16.6 shipped minos 15.0 with
      # byte-identical imported symbols and linked libraries. Pin minos back
      # to the macOS 14.0 policy ceiling (scripts/audit-portable-artifact.sh)
      # only when upstream is above it; binaries already at or below 14.0 are
      # left untouched. Runs before the fixup, which ad-hoc re-signs.
      ${pkgs.python3}/bin/python3 ${../..}/scripts/lower-macho-minos.py 14.0 $out/bin/postgrest
      ${pkgs.bash}/bin/bash ${../..}/scripts/portable-darwin-fixup.sh $out
    '';
  };
in
assert pkgs.stdenv.hostPlatform.isDarwin;
{
  inherit runtime;
  probeOrder = [ ];
  dependencyProbes = { };
  # PostgREST has no probed hashes: its one upstream artifact (assetUrl /
  # assetHash) is already resolved and pinned directly by the release
  # workflow before this flake ever evaluates.
  pinnedProbes = { };
}
