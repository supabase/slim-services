{
  pkgs,
  src,
  version,
  hashes,
  nodeMajor,
}:
let
  nodejs = pkgs."nodejs_${toString nodeMajor}";
  runtime = pkgs.buildNpmPackage {
    pname = "pgmeta-portable";
    inherit src version nodejs;
    npmDepsHash = hashes.npm_deps_hash or pkgs.lib.fakeHash;
    dontFixup = true;
    postPatch = ''
      substituteInPlace src/server/server.ts \
        --replace-fail \
        'const adminPort = PG_META_PORT + 1' \
        'const adminPort = Number(process.env.PG_META_ADMIN_PORT || PG_META_PORT + 1)'
    '';
    installPhase = ''
      runHook preInstall
      npm prune --omit=dev --offline
      mkdir -p $out/app
      cp package.json $out/app/
      cp -R dist node_modules $out/app/
      ${import ./node-runtime.nix {
        inherit pkgs nodeMajor;
        service = "pgmeta";
        command = "dist/server/server.js";
      }}
      runHook postInstall
    '';
  };
in
{
  inherit runtime;
  probeOrder = [ "npm_deps_hash" ];
  dependencyProbes.npm_deps_hash = runtime.npmDeps;
}
