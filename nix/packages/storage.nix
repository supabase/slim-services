{
  pkgs,
  src,
  version,
  hashes,
  nodeMajor,
  npmVersion,
}:
let
  inherit (pkgs) lib;
  nodejs = pkgs."nodejs_${toString nodeMajor}";
  npm = import ./npm-tool.nix {
    inherit pkgs nodejs;
    name = "npm";
    version = npmVersion;
    hash = hashes.npm_tool_hash or lib.fakeHash;
  };
  tools = pkgs.buildNpmPackage {
    pname = "storage-build-tools";
    version = "1.0.0";
    src = ./storage-tools;
    inherit nodejs;
    npmDepsHash = hashes.tools_deps_hash or lib.fakeHash;
    dontNpmBuild = true;
    installPhase = ''
      mkdir -p $out
      cp -R node_modules $out/
    '';
    dontFixup = true;
  };
  runtime = pkgs.buildNpmPackage {
    pname = "storage-portable";
    inherit src version nodejs;
    npmDepsHash = hashes.npm_deps_hash or lib.fakeHash;
    nativeBuildInputs = [ npm.package ];
    prePatch = ''
      export PATH=${npm.package}/bin:$PATH
    '';
    postPatch = ''
      cp ${../../services/storage/overlay/rolldown.config.mjs} rolldown.config.mjs
      cp ${../../services/storage/overlay/bundle-manifest.mjs} bundle-manifest.mjs
      cp ${../../services/storage/overlay/scripts/prepare-bundle-dist.mjs} scripts/prepare-bundle-dist.mjs
    '';
    buildPhase = ''
      runHook preBuild
      npm run build
      ln -s ${tools}/node_modules/rolldown node_modules/rolldown
      ${nodejs}/bin/node ${tools}/node_modules/rolldown/bin/cli.mjs -c ./rolldown.config.mjs --minify
      node scripts/prepare-bundle-dist.mjs
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/app/dist
      cp dist-bundle/package.json $out/app/package.json
      cp -R dist-bundle/start dist-bundle/scripts dist-bundle/static $out/app/dist/
      cp -R dist-bundle/node_modules migrations $out/app/
      ${import ./node-runtime.nix {
        inherit pkgs nodeMajor;
        service = "storage";
        command = "dist/start/server.js";
      }}
      runHook postInstall
    '';
    dontFixup = true;
  };
in
{
  inherit runtime;
  probeOrder = [
    "npm_tool_hash"
    "tools_deps_hash"
    "npm_deps_hash"
  ];
  dependencyProbes = {
    npm_tool_hash = npm.archive;
    tools_deps_hash = tools.npmDeps;
    npm_deps_hash = runtime.npmDeps;
  };
}
