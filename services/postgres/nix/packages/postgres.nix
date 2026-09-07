{
  pkgs,
  lib ? pkgs.lib,
  upstream,
  postgresqlPackages ? pkgs,
  portablePostgres ? throw "postgres package set requires portable-postgres helpers",
  nixpkgsRevision ? null,
}:
let
  extensionRoot = "${upstream}/nix/ext";
  # Minimal glibc locales for slim images - only en_US.UTF-8 (~3MB vs ~200MB)
  glibcLocalesMinimal = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [ "en_US.UTF-8/UTF-8" ];
  };

  # Custom extensions that exist in our repository. These aren't upstream
  # either because nobody has done the work, maintaining them here is
  # easier and more expedient, or because they may not be suitable, or are
  # too niche/one-off.
  #
  # Ideally, most of these should have copies upstream for third party
  # use, but even if they did, keeping our own copies means that we can
  # rollout new versions of these critical things easier without having to
  # go through the upstream release engineering process.
  ourExtensions = [
    "${extensionRoot}/rum.nix"
    "${extensionRoot}/timescaledb.nix"
    "${extensionRoot}/pgroonga"
    "${extensionRoot}/index_advisor.nix"
    "${extensionRoot}/wal2json.nix"
    "${extensionRoot}/pgmq"
    "${extensionRoot}/pg_repack.nix"
    "${extensionRoot}/pg-safeupdate.nix"
    "${extensionRoot}/plpgsql-check.nix"
    "${extensionRoot}/pgjwt.nix"
    "${extensionRoot}/pgaudit.nix"
    "${extensionRoot}/postgis.nix"
    "${extensionRoot}/pgrouting"
    "${extensionRoot}/pgtap.nix"
    "${extensionRoot}/pg_cron"
    "${extensionRoot}/pgsql-http.nix"
    "${extensionRoot}/pg_plan_filter.nix"
    "${extensionRoot}/pg_net.nix"
    "${extensionRoot}/pg_hashids.nix"
    "${extensionRoot}/pgsodium.nix"
    "${extensionRoot}/pg_graphql"
    "${extensionRoot}/pg_stat_monitor.nix"
    "${extensionRoot}/pg_jsonschema"
    "${extensionRoot}/pg_partman.nix"
    "${extensionRoot}/pgvector.nix"
    "${extensionRoot}/vault.nix"
    "${extensionRoot}/hypopg.nix"
    "${extensionRoot}/pg_tle.nix"
    "${extensionRoot}/wrappers/default.nix"
    "${extensionRoot}/supautils.nix"
    "${extensionRoot}/plv8"
  ];

  #Where we import and build the orioledb extension, we add on our custom extensions
  # plus the orioledb option
  #we're not using timescaledb or plv8 in the orioledb-17 version or pg 17 of supabase extensions
  orioleFilteredExtensions = builtins.filter (
    x:
    x != "${extensionRoot}/timescaledb.nix"
    && x != "${extensionRoot}/timescaledb-2.9.1.nix"
    && x != "${extensionRoot}/plv8"
  ) ourExtensions;

  orioledbExtensions = orioleFilteredExtensions ++ [ "${extensionRoot}/orioledb.nix" ];
  dbExtensions17 = orioleFilteredExtensions;

  # CLI extensions follow the matching upstream Dockerfile image set:
  # PG15 retains timescaledb/plv8 from ourExtensions, while PG17 uses the
  # filtered set because those extensions do not support PG17.
  cliExtensionsForVersion = version: if version == "17" then dbExtensions17 else ourExtensions;

  getPostgresqlPackage =
    version: latestOnly:
    let
      base = postgresqlPackages."postgresql_${version}";
    in
    if latestOnly then base.override { systemdSupport = false; } else base;
  # Create a 'receipt' file for a given postgresql package. This is a way
  # of adding a bit of metadata to the package, which can be used by other
  # tools to inspect what the contents of the install are: the PSQL
  # version, the installed extensions, et cetera.
  #
  # This takes two arguments:
  #  - pgbin: the postgresql package we are building on top of
  #    not a list of packages, but an attrset containing extension names
  #    mapped to versions.
  #  - ourExts: the list of extensions from upstream nixpkgs. This is not
  #    a list of packages, but an attrset containing extension names
  #    mapped to versions.
  #
  # The output is a package containing the receipt.json file, which can be
  # merged with the PostgreSQL installation using 'symlinkJoin'.
  makeReceipt =
    pgbin: ourExts:
    pkgs.writeTextFile {
      name = "receipt";
      destination = "/receipt.json";
      text = builtins.toJSON {
        psql-version = pgbin.version;
        nixpkgs = {
          revision = nixpkgsRevision;
        };
        extensions = ourExts;

        # NOTE this field can be used to do cache busting (e.g.
        # force a rebuild of the psql packages) but also to helpfully inform
        # tools what version of the schema is being used, for forwards and
        # backwards compatibility
        receipt-version = "1";
      };
    };

  makeOurPostgresPkgs =
    version:
    {
      variant ? "full",
      latestOnly ? false,
    }:
    let
      postgresql = getPostgresqlPackage version latestOnly;
      extensionsToUse =
        if variant == "cli" then
          cliExtensionsForVersion version
        else if (builtins.elem version [ "orioledb-17" ]) then
          orioledbExtensions
        else if (builtins.elem version [ "17" ]) then
          dbExtensions17
        else
          ourExtensions;
      extensionFetchFromGitHub =
        args:
        pkgs.fetchFromGitHub (
          args
          // lib.optionalAttrs ((args.owner or null) == "pgexperts" && (args.repo or null) == "plan_filter") {
            # The repository was renamed, but released Postgres tags still
            # reference its old name. Keep those immutable tags buildable.
            repo = "pg_plan_filter";
          }
        );
      # Nixpkgs' pinned fetchCrate still targets crates.io's API endpoint,
      # which now rejects these archive downloads. Keep this override
      # local to extension evaluation so unrelated packages retain their
      # normal registry configuration. The explicit registryDl argument,
      # when supplied by a caller, remains authoritative.
      packageScope =
        let
          staticCrateRegistry = "https://static.crates.io/crates";
          fetchCrate =
            args:
            pkgs.fetchCrate (
              args
              // lib.optionalAttrs (!(args ? registryDl)) {
                registryDl = staticCrateRegistry;
              }
            );
          makeRustPlatform =
            platformArgs:
            let
              baseRustPlatform = pkgs.makeRustPlatform platformArgs;
              importCargoLock = baseRustPlatform.importCargoLock.override {
                fetchurl =
                  args:
                  let
                    obsoleteRegistryPrefix = "https://crates.io/api/v1/crates/";
                    url = args.url or "";
                    rewrittenUrl =
                      if lib.hasPrefix obsoleteRegistryPrefix url then
                        staticCrateRegistry + "/" + lib.removePrefix obsoleteRegistryPrefix url
                      else
                        url;
                  in
                  pkgs.fetchurl (args // { url = rewrittenUrl; });
              };
            in
            baseRustPlatform
            // {
              inherit importCargoLock;
              buildRustPackage = baseRustPlatform.buildRustPackage.override {
                inherit importCargoLock;
              };
            };
        in
        pkgs
        // {
          inherit fetchCrate makeRustPlatform;
          callPackage = lib.callPackageWith packageScope;
          callPackages = lib.callPackagesWith packageScope;
        };
      extCallPackage = lib.callPackageWith (
        packageScope
        // {
          inherit postgresql latestOnly;
          fetchFromGitHub = extensionFetchFromGitHub;
          switch-ext-version = extCallPackage "${upstream}/nix/packages/switch-ext-version.nix" { };
          overlayfs-on-package = extCallPackage "${upstream}/nix/packages/overlayfs-on-package.nix" { };
        }
      );
    in
    map (path: extCallPackage path { }) extensionsToUse;

  # Create an attrset that contains all the extensions included in a server.
  makeOurPostgresPkgsSet =
    version:
    {
      variant ? "full",
      latestOnly ? false,
    }:
    let
      pkgsList = makeOurPostgresPkgs version { inherit variant latestOnly; };
      baseAttrs = builtins.listToAttrs (
        map (drv: {
          name = drv.name;
          value = drv;
        }) pkgsList
      );
      # Expose individual packages from extensions that have them in passthru.packages
      # This makes them discoverable by nix-eval-jobs --force-recurse
      individualPkgs = lib.concatMapAttrs (
        name: drv: lib.optionalAttrs (drv ? passthru.packages) { "${name}-pkgs" = drv.passthru.packages; }
      ) baseAttrs;
    in
    baseAttrs // individualPkgs // { recurseForDerivations = true; };

  # Create a binary distribution of PostgreSQL, given a version.
  #
  # NOTE: The version here does NOT refer to the exact PostgreSQL version;
  # it refers to the *major number only*, which is used to select the
  # correct version of the package from nixpkgs. This is because we want
  # to be able to do so in an open ended way. As an example, the version
  # "15" passed in will use the nixpkgs package "postgresql_15" as the
  # basis for building extensions, etc.
  makePostgresBin =
    version:
    {
      variant ? "full",
      latestOnly ? false,
    }:
    let
      # For CLI variant, override PostgreSQL to be portable (no hardcoded /nix/store paths)
      postgresql =
        let
          base = getPostgresqlPackage version latestOnly;
        in
        if variant == "cli" then base.override { portable = true; } else base;
      postgres-pkgs = makeOurPostgresPkgs version { inherit variant latestOnly; };
      ourExts = map (ext: {
        name = ext.name;
        version = ext.version;
      }) postgres-pkgs;

      pgbin = postgresql.withPackages (_ps: postgres-pkgs);

      # For slim packages, include minimal glibc locales for initdb locale support
      extraPaths = lib.optionals (latestOnly && pkgs.stdenv.isLinux) [
        glibcLocalesMinimal
      ];
    in
    pkgs.symlinkJoin {
      inherit (pgbin) name version;
      paths = [
        pgbin
        (makeReceipt pgbin ourExts)
      ]
      ++ extraPaths;
    };

  # Create an attribute set, containing all the relevant packages for a
  # PostgreSQL install, wrapped up with a bow on top. There are three
  # packages:
  #
  #  - bin: the postgresql package itself, with all the extensions
  #    installed, and a receipt.json file containing metadata about the
  #    install.
  #  - exts: an attrset containing all the extensions, mapped to their
  #    package names.
  makePostgres =
    version:
    {
      variant ? "full",
      latestOnly ? false,
    }:
    lib.recurseIntoAttrs {
      bin = makePostgresBin version { inherit variant latestOnly; };
      exts = makeOurPostgresPkgsSet version { inherit variant latestOnly; };
    };
  basePackages = {
    psql_15 = makePostgres "15" { };
    psql_17 = makePostgres "17" { };
    psql_orioledb-17 = makePostgres "orioledb-17" { };
  };
  slimPackages = {
    psql_15_slim = makePostgres "15" { latestOnly = true; };
    psql_17_slim = makePostgres "17" { latestOnly = true; };
    psql_orioledb-17_slim = makePostgres "orioledb-17" { latestOnly = true; };
  };

  # CLI packages - latest-only PostgreSQL plus the full extension set used
  # by the corresponding upstream Docker image.
  cliPackages = {
    psql_15_cli = makePostgres "15" {
      variant = "cli";
      latestOnly = true;
    };
    psql_17_cli = makePostgres "17" {
      variant = "cli";
      # slim-services overlay: ship only the LATEST version of each
      # extension. The default builds every historical version (16x
      # wrappers, 17x pg_graphql, ... — mostly large pgrx cdylibs), which
      # ballooned the portable rootfs to ~5 GiB. latestOnly also bundles
      # glibcLocalesMinimal on Linux (initdb locale support).
      latestOnly = true;
    };
  };

  # PG15 portable output is added by this overlay. The pinned source's
  # default package module already exports psql_17_cli_portable; because
  # this overlay replaces its postgres-portable.nix, both major paths use
  # the same matched-loader/glibc fixup.
  portablePackages = {
    psql_15_cli_portable = pkgs.callPackage ./postgres-portable.nix {
      inherit upstream portablePostgres;
      psql_cli = cliPackages.psql_15_cli;
      postgres_major = "15";
    };
  };

  binPackages = lib.mapAttrs' (name: value: {
    name = "${name}/bin";
    value = value.bin;
  }) (basePackages // slimPackages // cliPackages);
in
{
  packages = binPackages // portablePackages;
  legacyPackages = basePackages // slimPackages // cliPackages;
}
