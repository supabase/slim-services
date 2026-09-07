# npm and pnpm publish self-contained CLI tarballs with bundled dependencies.
{
  pkgs,
  nodejs,
  name,
  version,
  hash,
}:
let
  archive = pkgs.fetchurl {
    url = "https://registry.npmjs.org/${name}/-/${name}-${version}.tgz";
    inherit hash;
  };
  package = pkgs.stdenvNoCC.mkDerivation {
    pname = name;
    inherit version;
    src = archive;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
            mkdir -p $out/libexec $out/bin
            cp -R . $out/libexec/${name}
            cat > $out/bin/${name} <<SH
      #!${pkgs.runtimeShell}
      exec ${nodejs}/bin/node $out/libexec/${name}/bin/${
        if name == "npm" then "npm-cli.js" else "pnpm.cjs"
      } "\$@"
      SH
            chmod +x $out/bin/${name}
    '';
  };
in
{
  inherit archive package;
}
