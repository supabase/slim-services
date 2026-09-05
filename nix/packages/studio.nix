{
  pkgs,
  src,
  version,
  hashes,
  nodeMajor,
  pnpmVersion,
  studioFramework,
  runtimeNixpkgsSrc,
}:
let
  inherit (pkgs) lib;
  nodejs = pkgs."nodejs_${toString nodeMajor}";
  # The pinned runtime package set owns the pnpm 11 store helper; keep the
  # service build toolchain on the shared package set and its Node floor.
  runtimePkgs = import runtimeNixpkgsSrc {
    system = pkgs.stdenv.hostPlatform.system;
  };
  pnpm = import ./npm-tool.nix {
    inherit pkgs nodejs;
    name = "pnpm";
    version = pnpmVersion;
    hash = hashes.pnpm_tool_hash or lib.fakeHash;
  };
  packageJson = builtins.fromJSON (builtins.readFile (src + "/package.json"));
  turboVersion = packageJson.devDependencies.turbo;
  lockfile = builtins.readFile (src + "/pnpm-lock.yaml");
  platform = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux";
  arch = if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "64";
  usesScopedTurboPackage = builtins.replaceStrings [ "@turbo/" ] [ "" ] lockfile != lockfile;
  turboPackage =
    if usesScopedTurboPackage then "@turbo/${platform}-${arch}" else "turbo-${platform}-${arch}";
  turboArchive = pkgs.fetchurl {
    url =
      if usesScopedTurboPackage then
        "https://registry.npmjs.org/@turbo/${platform}-${arch}/-/${platform}-${arch}-${turboVersion}.tgz"
      else
        "https://registry.npmjs.org/${turboPackage}/-/${turboPackage}-${turboVersion}.tgz";
    hash = hashes.turbo_tool_hash or lib.fakeHash;
  };
  turbo = pkgs.stdenvNoCC.mkDerivation {
    pname = "turbo-studio";
    version = turboVersion;
    src = turboArchive;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''mkdir -p $out/bin; cp bin/turbo $out/bin/'';
  };
  workspace = pkgs.stdenvNoCC.mkDerivation {
    pname = "studio-workspace";
    inherit src version;
    nativeBuildInputs = [
      turbo
      nodejs
    ];
    buildPhase = ''
      export HOME=$TMPDIR/home
      mkdir -p $HOME
      export TURBO_TELEMETRY_DISABLED=1
      turbo prune studio --docker
    '';
    installPhase = ''
      mkdir -p $out
      cp -R out/json/. $out/
      cp out/pnpm-lock.yaml $out/pnpm-lock.yaml
      cp -R out/full/. $out/
      if [ -d patches ]; then cp -R patches $out/; fi
    '';
    dontFixup = true;
  };
  pnpmForDeps = pnpm.package.overrideAttrs (_: {
    passthru = {
      nodejs-slim = nodejs;
    };
  });
  pnpmDeps = runtimePkgs.fetchPnpmDeps {
    pname = "studio";
    inherit version;
    src = workspace;
    pnpm = pnpmForDeps;
    fetcherVersion = 4;
    hash = hashes.pnpm_deps_hash or lib.fakeHash;
    prePnpmInstall = ''
      export NIX_NPM_REGISTRY="''${NIX_NPM_REGISTRY:-https://registry.npmjs.org}"
    '';
  };
  runtime = pkgs.stdenv.mkDerivation {
    pname = "studio-portable";
    inherit version;
    src = workspace;
    nativeBuildInputs = [
      nodejs
      pnpm.package
      runtimePkgs.pnpmConfigHook
      pkgs.python3
      pkgs.pkg-config
      pkgs.git
    ];
    inherit pnpmDeps;
    env = {
      NEXT_TELEMETRY_DISABLED = "1";
      TURBO_TELEMETRY_DISABLED = "1";
      npm_config_nodedir = "${nodejs}";
      npm_config_offline = "true";
      NODE_OPTIONS = "--max-old-space-size=4096";
    };
    buildPhase = ''
      runHook preBuild
      ${
        if studioFramework == "next" then
          ''
            pnpm --filter studio exec next build
          ''
        else if studioFramework == "tanstack" then
          ''
            pnpm --filter studio run build:tanstack
          ''
        else
          throw "unsupported Studio framework: ${studioFramework}"
      }
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/app/apps/studio
      ${
        if studioFramework == "next" then
          ''
            ${pkgs.bash}/bin/bash ${../../services/studio/normalize-next-standalone.sh} \
              apps/studio/.next/standalone "$PWD/node_modules/.pnpm"
            cp -R apps/studio/.next/standalone/. $out/app/
            mkdir -p $out/app/apps/studio/.next
            cp -R apps/studio/.next/static $out/app/apps/studio/.next/
            cp -R apps/studio/public $out/app/apps/studio/
          ''
        else
          ''
            pnpm --filter studio deploy --prod --legacy --ignore-scripts $TMPDIR/deploy
            find $TMPDIR/deploy -mindepth 1 -maxdepth 1 \
              ! -name node_modules ! -name package.json ! -name scripts \
              ! -name instrument.server.mjs ! -name .env -exec rm -rf {} +
            cp -R $TMPDIR/deploy/. $out/app/apps/studio/
            cp -R apps/studio/dist $out/app/apps/studio/
            printf "import('./scripts/serve.js')\n" > $out/app/apps/studio/server.js
            (cd $out/app/apps/studio; node scripts/smoke-server.mjs)
          ''
      }
      cp ${../../services/studio/overlay/docker-entrypoint.mjs} $out/app/apps/studio/docker-entrypoint.mjs
      ${import ./node-runtime.nix {
        inherit pkgs nodeMajor;
        service = "studio";
        command = ''apps/studio/docker-entrypoint.mjs "$NODE_BIN" apps/studio/server.js'';
      }}
      ${pkgs.bash}/bin/bash ${../..}/services/studio/validate-artifact.sh $out
      runHook postInstall
    '';
    dontFixup = true;
  };
in
{
  inherit runtime;
  probeOrder = [
    "pnpm_tool_hash"
    "turbo_tool_hash"
    "pnpm_deps_hash"
  ];
  dependencyProbes = {
    pnpm_tool_hash = pnpm.archive;
    turbo_tool_hash = turboArchive;
    pnpm_deps_hash = pnpmDeps;
  };
}
