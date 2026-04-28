{ system ? builtins.currentSystem
, sourceDir ? /src
, compiler ? "ghc9123"
, nixpkgsVersion ? {
    owner = "nixos";
    repo = "nixpkgs";
    rev = "01fbdeef22b76df85ea168fbfe1bfd9e63681b30";
    tarballHash = "sha256-GMSVw35Q+294GlrTUKlx087E31z7KurReQ1YHSKp5iw=";
  }
}:

let
  upstream =
    import sourceDir {
      inherit compiler nixpkgsVersion system;
    };

  pkgsStatic =
    upstream.pkgs.pkgsStatic.extend (_: prev: {
      haskell = prev.haskell // {
        packages = prev.haskell.packages // {
          native-bignum = prev.haskell.packages.native-bignum // {
            "${compiler}" =
              prev.haskell.packages.native-bignum."${compiler}".override {
                overrides = final: previous: {
                  network = prev.haskell.lib.dontCheck previous.network;
                };
              };
          };
        };
      };
    });

  inherit (pkgsStatic.haskell) lib;

  src =
    upstream.pkgs.lib.sourceFilesBySuffices
      (upstream.pkgs.gitignoreSource sourceDir)
      [ ".cabal" ".hs" ".lhs" "LICENSE" ];

  packagesStatic = pkgsStatic.haskell.packages.native-bignum."${compiler}";

  postgrestDrv =
    lib.overrideCabal
      (lib.doJailbreak (packagesStatic.callCabal2nix "postgrest" src { }))
      (old: {
        configureFlags = (old.configureFlags or [ ]) ++ [
          "--ghc-options=-Wwarn"
        ];
      });

  makeExecutableStatic = drv: upstream.pkgs.lib.pipe drv [
    lib.compose.justStaticExecutables
    (drv: drv.overrideAttrs {
      allowedReferences = [
        pkgsStatic.openssl.etc
      ];
    })
    (drv: drv.overrideAttrs {
      passthru.tests.version = pkgsStatic.testers.testVersion {
        package = drv;
      };
    })
  ];
in
{
  inherit packagesStatic;

  postgrestStatic = makeExecutableStatic postgrestDrv;
}
