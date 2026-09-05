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
      ${pkgs.bash}/bin/bash ${../..}/scripts/portable-darwin-fixup.sh $out
    '';
  };
in
assert pkgs.stdenv.hostPlatform.isDarwin;
{
  inherit runtime;
  probeOrder = [ ];
  dependencyProbes = { };
}
