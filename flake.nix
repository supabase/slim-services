{
  description = "Reproducible native artifacts and portable Supabase CLI runtimes";

  # Postgres publishes its source-build closure to this public cache. The
  # release wrappers accept flake configuration explicitly, so source builds
  # remain the fallback when a caller opts out or the cache has no match.
  nixConfig = {
    extra-substituters = [ "https://nix-postgres-artifacts.s3.amazonaws.com" ];
    extra-trusted-public-keys = [
      "nix-postgres-artifacts:dGZlQOvKcNEjvT7QEAJbcV6b6uk7VF/hWMjhYleiaLI="
    ];
  };

  inputs = {
    # This is the shared build package set. It is deliberately separate from
    # runtime-nixpkgs: the latter supplies versioned interpreter definitions
    # while this snapshot preserves the established host compatibility floor.
    nixpkgs.url = "github:NixOS/nixpkgs/ac62194c3917d5f474c1a844b6fd6da2db95077d";
    nixpkgs.flake = false;
    runtime-nixpkgs.url = "github:NixOS/nixpkgs/b7c2ada94fe99c15b0dbcf4d11fd7850b957a436";
    runtime-nixpkgs.flake = false;
    rust-overlay.url = "github:oxalica/rust-overlay/57a23bfaf4f7017267294b161175db1e32eb1c85";
    rust-overlay.flake = false;

    # Release automation overrides this input with a temporary directory that
    # contains release.json and the exact upstream source under source/.
    release.url = "path:./nix/release";
    release.flake = false;

    # Nested upstream flakes (Postgres and Edge Runtime) are supplied through
    # this input by release automation. A real source keeps its own flake.lock;
    # the checked-in placeholder keeps ordinary evaluation self-contained.
    upstream.url = "path:./nix/upstream-empty";
  };

  outputs =
    inputs@{ self, ... }:
    let
      packageSet = import ./nix/packages.nix { inherit inputs; };
      packages = packageSet.forAllSystems (
        system:
        let
          p = packageSet.mkPackages system;
        in
        if packageSet.hasReleaseRootfs then
          {
            default = p.archive;
            archive = p.archive;
          }
          // (
            if
              packageSet.hasReleaseImage
              && builtins.elem system [
                "x86_64-linux"
                "aarch64-linux"
              ]
            then
              {
                image = p.image;
              }
            else
              { }
          )
        else
          {
            default = p.runtime;
            runtime = p.runtime;
            "${packageSet.releaseService}" = p.runtime;
            postgresql_16 = p.postgresql_16;
          }
          // (
            if packageSet.releaseService == "portable-node" then
              { }
            else
              {
                portable-node = p.portable-node;
              }
          )
      );
    in
    {
      inherit packages;
      legacyPackages = packageSet.forAllSystems packageSet.mkPackages;
      lib = {
        inherit (packageSet) systems mkPackages;
      };
    };
}
