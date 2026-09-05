{ inputs }:
let
  inherit (inputs)
    nixpkgs
    runtime-nixpkgs
    rust-overlay
    release
    upstream
    ;
  releaseData = builtins.fromJSON (builtins.readFile "${release}/release.json");
  hasReleaseRootfs = builtins.pathExists "${release}/rootfs";
  # Image packaging is explicit in the release input created by
  # build-image-from-artifact.sh. Archives carry rootfs plus archive metadata
  # only, so they never enter this branch.
  hasReleaseImage = hasReleaseRootfs && releaseData ? image_tag;
  releaseHashes = releaseData.hashes or { };
  releaseService =
    releaseData.service
      or (if hasReleaseRootfs then "artifact" else throw "release.json must define service");
  releaseVersion =
    releaseData.version
      or (if hasReleaseRootfs then "dev" else throw "release.json must define version");
  releaseSourcePath = "${release}/source";
  hasReleaseSource = builtins.pathExists "${releaseSourcePath}/.";
  releaseSource =
    if hasReleaseSource then
      builtins.path {
        path = releaseSourcePath;
        name = "release-source";
      }
    else
      null;
  requireReleaseSource =
    if releaseSource != null then
      releaseSource
    else
      throw "release input must contain source/ for ${releaseService}";
  hash = name: releaseHashes.${name} or null;

  mkPackages =
    system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
      };
      common = {
        inherit pkgs;
        serviceVersion = releaseVersion;
        src = requireReleaseSource;
        derivedHashes = releaseHashes;
      };
      beamArgs = common // {
        runtimeNixpkgsSrc = runtime-nixpkgs;
        upstreamDockerfile = builtins.readFile "${requireReleaseSource}/Dockerfile";
        portableBeam = ../nix/portable-beam;
        mixDepsHash = hash "mix_deps_hash";
      };
      realtimeSet = import ../services/realtime/nix/default.nix beamArgs;
      analyticsSet = import ../services/analytics/nix/default.nix (
        beamArgs
        // {
          rustOverlaySrc = rust-overlay;
          explorerNifHash = hash "explorer_nif_hash";
          sqlFmtNifHash = hash "sql_fmt_nif_hash";
        }
      );
      poolerSet = import ../services/pooler/nix/default.nix beamArgs;
      authSet = import ./packages/auth.nix {
        inherit pkgs;
        src = requireReleaseSource;
        version = releaseVersion;
        hashes = releaseHashes;
      };
      pgmetaSet = import ./packages/pgmeta.nix {
        inherit pkgs;
        src = requireReleaseSource;
        version = releaseVersion;
        hashes = releaseHashes;
        nodeMajor = releaseData.nodeMajor or 24;
      };
      storageSet = import ./packages/storage.nix {
        inherit pkgs;
        src = requireReleaseSource;
        version = releaseVersion;
        hashes = releaseHashes;
        nodeMajor = releaseData.nodeMajor or 24;
        npmVersion = releaseData.npmVersion or (throw "storage release requires npmVersion");
      };
      studioSet = import ./packages/studio.nix {
        inherit pkgs;
        src = requireReleaseSource;
        version = releaseVersion;
        hashes = releaseHashes;
        nodeMajor = releaseData.nodeMajor or 24;
        pnpmVersion = releaseData.pnpmVersion or (throw "studio release requires pnpmVersion");
        studioFramework = releaseData.studioFramework or (throw "studio release requires studioFramework");
      };
      postgrestSet = import ./packages/postgrest.nix {
        inherit pkgs;
        version = releaseVersion;
        assetUrl = releaseData.assetUrl or (throw "postgrest release requires assetUrl");
        assetHash = releaseData.assetHash or (throw "postgrest release requires assetHash");
      };
      # Edge Runtime's source flake owns its nixpkgs input. Reuse that exact
      # package set so its Rust toolchain and native dependency versions stay
      # tied to the release lock rather than to this flake's shared tools.
      edgePkgs =
        if upstream ? inputs && upstream.inputs ? nixpkgs then
          upstream.inputs.nixpkgs.legacyPackages.${system}
        else
          pkgs;
      edgeRuntime = import ../services/edge-runtime/nix/edge-runtime.nix (
        (builtins.removeAttrs common [ "pkgs" ])
        // {
          rustPlatform = edgePkgs.rustPlatform;
          inherit (edgePkgs)
            lib
            stdenv
            openblas
            onnxruntime
            pkg-config
            patchelf
            curl
            fetchurl
            cmake
            openssl
            zstd
            ;
          v8ArchiveHash = hash "v8_archive_hash";
          v8BindingHash = hash "v8_binding_hash";
          cargoHash = hash "cargo_hash";
        }
      );
      imgproxySet = import ../services/imgproxy/nix/default.nix {
        inherit pkgs;
        serviceVersion = releaseVersion;
        sourceRepository = releaseData.sourceRepository;
        sourceCommit = releaseData.source.commit;
        sourceHash = releaseData.source.fetch_from_github_hash;
        vendorHash = releaseHashes.vendorHash or releaseData.source.vendorHash or pkgs.lib.fakeHash;
      };
      postgresMajor =
        let
          major = releaseData.postgresMajor or (builtins.head (builtins.split "\\." releaseVersion));
        in
        if
          builtins.elem major [
            "15"
            "17"
          ]
        then
          major
        else
          throw "postgres release must select major 15 or 17 (got ${major})";
      hasPostgresNixpkgs =
        upstream ? inputs
        && upstream.inputs ? nixpkgs
        && builtins.pathExists "${requireReleaseSource}/nix/nixpkgs.nix";
      postgresPkgs =
        if hasPostgresNixpkgs then
          let
            upstreamNixpkgs = import "${requireReleaseSource}/nix/nixpkgs.nix" {
              self = upstream;
              inputs = upstream.inputs;
            };
          in
          (upstreamNixpkgs.perSystem { inherit system; })._module.args.pkgs
        else
          pkgs;
      postgresPackages = import ../services/postgres/nix/packages/postgres.nix {
        pkgs = postgresPkgs;
        upstream = requireReleaseSource;
        postgresqlPackages = upstream.packages.${system};
        portablePostgres = ../portable-postgres;
        nixpkgsRevision = if hasPostgresNixpkgs then upstream.inputs.nixpkgs.rev else nixpkgs.rev or null;
      };
      postgresPortable =
        postgresPkgs.callPackage ../services/postgres/nix/packages/postgres-portable.nix
          {
            upstream = requireReleaseSource;
            portablePostgres = ../portable-postgres;
            psql_cli = if postgresMajor == "15" then postgresPackages.legacyPackages.psql_15_cli else null;
            psql_17_cli = if postgresMajor == "17" then postgresPackages.legacyPackages.psql_17_cli else null;
            postgres_major = postgresMajor;
          };
      nodeMajor = releaseData.nodeMajor or 24;
      portableNode = import ./portable-node/default.nix { inherit pkgs nodeMajor; };
      archive =
        if hasReleaseRootfs then
          import ./archive.nix {
            inherit pkgs;
            rootfs = "${release}/rootfs";
            name = releaseData.archive_prefix or releaseService;
          }
        else
          null;
      image =
        if
          hasReleaseImage
          && builtins.elem system [
            "x86_64-linux"
            "aarch64-linux"
          ]
        then
          import ./images/default.nix {
            inherit pkgs;
            service = releaseService;
            rootfs = "${release}/rootfs";
            tag = releaseData.image_tag;
            identity = releaseData.identity or { };
            labels = releaseData.labels or { };
          }
        else
          null;
      selected =
        if releaseService == "realtime" then
          realtimeSet.realtime
        else if releaseService == "analytics" then
          analyticsSet.logflare
        else if releaseService == "pooler" then
          poolerSet.supavisor
        else if releaseService == "auth" then
          authSet.runtime
        else if releaseService == "pgmeta" then
          pgmetaSet.runtime
        else if releaseService == "storage" then
          storageSet.runtime
        else if releaseService == "studio" then
          studioSet.runtime
        else if releaseService == "postgrest" then
          postgrestSet.runtime
        else if releaseService == "edge-runtime" then
          edgeRuntime
        else if releaseService == "imgproxy" then
          imgproxySet.imgproxy
        else if releaseService == "postgres" then
          postgresPortable
        else if releaseService == "portable-node" then
          portableNode
        else
          throw "unsupported native release service: ${releaseService}";
      # Runtime pruning belongs to the Nix output so every consumer (archive,
      # image, or direct artifact export) sees the same final tree. Keep the
      # repository root as the script context: the helper also copies the
      # repository's license notices before removing documentation.
      runtime =
        if hasReleaseRootfs then
          archive
        else
          pkgs.runCommand "${releaseService}-runtime"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                findutils
                gawk
                gnugrep
                gnused
              ];
            }
            ''
              mkdir -p "$out"
              cp -a ${selected}/. "$out/"
              chmod -R u+w "$out"
              ${pkgs.bash}/bin/bash ${../.}/scripts/prune-runtime-tree.sh "$out"
            '';
      probes =
        if releaseService == "realtime" then
          { mix_deps_hash = realtimeSet.mix-deps; }
        else if releaseService == "analytics" then
          {
            mix_deps_hash = analyticsSet.mix-deps;
            explorer_nif_hash = analyticsSet.explorer-nif;
            sql_fmt_nif_hash = analyticsSet.sql-fmt-nif;
          }
        else if releaseService == "pooler" then
          { mix_deps_hash = poolerSet.mix-deps; }
        else if releaseService == "auth" then
          authSet.dependencyProbes
        else if releaseService == "pgmeta" then
          pgmetaSet.dependencyProbes
        else if releaseService == "storage" then
          storageSet.dependencyProbes
        else if releaseService == "studio" then
          studioSet.dependencyProbes
        else if releaseService == "postgrest" then
          postgrestSet.dependencyProbes
        else if releaseService == "edge-runtime" then
          {
            v8_archive_hash = edgeRuntime.passthru.fixedOutputs.v8Archive;
            v8_binding_hash = edgeRuntime.passthru.fixedOutputs.v8Binding;
            cargo_hash = edgeRuntime.passthru.fixedOutputs.cargoDeps;
          }
        else if releaseService == "postgres" then
          { }
        else if releaseService == "imgproxy" then
          { vendorHash = imgproxySet.goModules; }
        else
          { };
      probeOrder =
        if releaseService == "realtime" then
          [ "mix_deps_hash" ]
        else if releaseService == "analytics" then
          [
            "explorer_nif_hash"
            "sql_fmt_nif_hash"
            "mix_deps_hash"
          ]
        else if releaseService == "pooler" then
          [ "mix_deps_hash" ]
        else if releaseService == "edge-runtime" then
          [
            "v8_archive_hash"
            "v8_binding_hash"
            "cargo_hash"
          ]
        else if releaseService == "imgproxy" then
          [ "vendorHash" ]
        else if releaseService == "auth" then
          authSet.probeOrder
        else if releaseService == "pgmeta" then
          pgmetaSet.probeOrder
        else if releaseService == "storage" then
          storageSet.probeOrder
        else if releaseService == "studio" then
          studioSet.probeOrder
        else if releaseService == "postgrest" then
          postgrestSet.probeOrder
        else
          [ ];
    in
    {
      inherit runtime;
      # Packaging inputs contain an already audited rootfs and deliberately do
      # not carry an upstream source. Keep runtime-only attrs out of that
      # evaluation path while retaining them for normal release inputs.
      dependencyProbes = if hasReleaseRootfs then { } else probes;
      # The host-process smoke harness uses a plain PostgreSQL server. Keep
      # this small tooling export independent from the selected release
      # service so it remains available in the default flake evaluation.
      postgresql_16 = pkgs.postgresql_16;
      probeOrder = if hasReleaseRootfs then [ ] else probeOrder;
    }
    // (if hasReleaseRootfs then { inherit archive; } else { })
    // (
      if
        hasReleaseImage
        && builtins.elem system [
          "x86_64-linux"
          "aarch64-linux"
        ]
      then
        { inherit image; }
      else
        { }
    )
    // (if hasReleaseRootfs then { } else { "${releaseService}" = selected; })
    // (
      if hasReleaseRootfs || releaseService == "portable-node" then
        { }
      else
        {
          portable-node = portableNode;
        }
    );

  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "aarch64-darwin"
  ];
  forAllSystems =
    f:
    builtins.listToAttrs (
      map (system: {
        name = system;
        value = f system;
      }) systems
    );
in
{
  inherit
    systems
    mkPackages
    forAllSystems
    releaseService
    hasReleaseRootfs
    hasReleaseImage
    ;
}
