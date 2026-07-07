# Repo-owned portable Nix package for Analytics / Logflare (darwin
# host-native artifacts). Same pattern as services/realtime/nix/default.nix;
# see that file and NIX_PORTABLE_ARTIFACT_PLAYBOOK.md for the packaging notes.
#
# Logflare-specific packaging:
# - Four in-tree rustler NIF crates (native/*), members of a cargo workspace
#   rooted at the repo top level. Dependencies are vendored once via
#   importCargoLock from the workspace Cargo.lock.
# - explorer and sql_fmt use rustler_precompiled, which downloads a
#   precompiled NIF during compilation. The sandbox has no network, so the
#   pinned darwin tarballs are fetched as fixed-output derivations and seeded
#   into the rustler_precompiled cache (checksums are verified against the
#   checksum file inside each hex package).
# - config/prod.exs sets cache_static_manifest; the asset pipeline (npm/
#   esbuild) is skipped like realtime's, so a stub cache_manifest.json is
#   installed to keep endpoint boot happy (UI assets 404, API unaffected).
# - Pin: nixos-unstable rather than the 25.05 pin the other services use —
#   the rustler 0.37 crates require rustc >= 1.91 (25.05 ships 1.86) and
#   unstable also provides Elixir 1.19.5, the exact Docker builder version.
{
  pkgs ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/d407951447dcd00442e97087bf374aad70c04cea.tar.gz";
    sha256 = "1jgfnvi57n79zsfljh2i4b77yj6wh028z4r3wf223am8wznzqbzj";
  }) { },
}:
let
  lib = pkgs.lib;
  beamPackages = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_27;
  elixir = beamPackages.elixir_1_19;
  fetchMixDeps = beamPackages.fetchMixDeps.override { inherit elixir; };
  mixRelease = beamPackages.mixRelease.override { inherit elixir fetchMixDeps; };

  pname = "logflare";
  version = "1.46.0";

  src = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString ../. + "/") (toString path);
      in
      # docs/ stays: compiling docs_view.ex copies docs/docs.logflare.com
      # into priv/docs.
      !(lib.hasPrefix "nix" rel)
      && !(lib.hasPrefix ".git" rel)
      && !(lib.hasPrefix "test" rel)
      && !(lib.hasPrefix "cloudbuild" rel);
  };

  cargoDeps = pkgs.rustPlatform.importCargoLock {
    lockFile = ../Cargo.lock;
  };

  # Pinned rustler_precompiled artifacts (darwin-arm64, NIF 2.15 — the same
  # variant the Linux artifact resolves under OTP 27).
  explorerNif = pkgs.fetchurl {
    url = "https://github.com/elixir-explorer/explorer/releases/download/v0.11.1/libexplorer-v0.11.1-nif-2.15-aarch64-apple-darwin.so.tar.gz";
    sha256 = "8ffac3a1c4308b9e248ad48a5d184dba8c3cac13110c315a763fc29d0d42361d";
  };
  sqlFmtNif = pkgs.fetchurl {
    url = "https://github.com/akoutmos/sql_fmt/releases/download/v0.4.0/libsql_fmt_nif-v0.4.0-nif-2.15-aarch64-apple-darwin.so.tar.gz";
    sha256 = "d528525334a051071859079e360ec2966d2bfd4f200bf539d1856602450e3a0e";
  };

  release = mixRelease {
    inherit pname version src;
    mixEnv = "prod";

    mixFodDeps = fetchMixDeps {
      pname = "mix-deps-${pname}";
      inherit version src;
      hash = "sha256-FZBKV1pYocd6RX+XS3fjt84V4MwrZEnSOflwArmz7OA=";
      mixEnv = "prod";
    };

    nativeBuildInputs = [
      pkgs.cargo
      pkgs.rustc
    ];

    preConfigure = ''
      # rustler_precompiled checks its cache before hitting the network;
      # seed it with the pinned darwin NIF tarballs (both basedir layouts).
      export HOME="$TMPDIR/home"
      for cache in "$HOME/Library/Caches/rustler_precompiled/precompiled_nifs" \
                   "$HOME/.cache/rustler_precompiled/precompiled_nifs"; do
        mkdir -p "$cache"
        cp ${explorerNif} "$cache/libexplorer-v0.11.1-nif-2.15-aarch64-apple-darwin.so.tar.gz"
        cp ${sqlFmtNif} "$cache/libsql_fmt_nif-v0.4.0-nif-2.15-aarch64-apple-darwin.so.tar.gz"
      done

      # Vendor cargo deps once for the whole native/* workspace; cargo
      # discovers the config walking up from each crate to the repo root.
      mkdir -p .cargo
      cat ${cargoDeps}/.cargo/config.toml >> .cargo/config.toml
      ln -sfn ${cargoDeps} cargo-vendor-dir
    '';

    removeCookie = false;
  };
in
{
  logflare = pkgs.stdenv.mkDerivation {
    name = "${pname}-portable";
    inherit version;
    dontUnpack = true;
    dontPatchShebangs = true;
    dontStrip = true;
    nativeBuildInputs = [ pkgs.python3 pkgs.file ];

    buildPhase = ''
      rootfs="$out"
      mkdir -p "$rootfs"

      cp -R ${release}/. "$rootfs/"
      chmod -R u+w "$rootfs"

      rm -rf "$rootfs"/erts-*/src "$rootfs"/erts-*/doc "$rootfs"/erts-*/man \
             "$rootfs"/erts-*/include "$rootfs"/erts-*/lib/internal
      find "$rootfs/lib" -type d \( -name src -o -name include -o -name doc \) \
        -prune -exec rm -rf {} + 2>/dev/null || true
      rm -f "$rootfs"/erts-*/bin/*.src "$rootfs"/erts-*/bin/start

      # The asset pipeline is skipped; prod.exs configures
      # cache_static_manifest, so install an empty manifest to keep the
      # endpoint bootable (UI assets 404, API unaffected).
      for privdir in "$rootfs"/lib/logflare-*/priv; do
        mkdir -p "$privdir/static"
        printf '{"latest":{},"digests":{},"version":1}\n' > "$privdir/static/cache_manifest.json"
      done

      for wrapped in "$rootfs"/bin/.*-wrapped; do
        [ -f "$wrapped" ] || continue
        name="$(basename "$wrapped")"
        name="''${name#.}"
        name="''${name%-wrapped}"
        mv -f "$wrapped" "$rootfs/bin/$name"
        chmod 0755 "$rootfs/bin/$name"
      done
    '';

    postFixup = ''
      rootfs="$out"

      grep -rl '^#![ ]*/nix/store' "$rootfs" 2>/dev/null | while read -r script; do
        sed -i -E '1s|^#![ ]*/nix/store/[^ /]*/bin/([a-z0-9]+)( .*)?$|#!/bin/\1\2|' "$script"
      done
    '' + lib.optionalString pkgs.stdenv.isDarwin ''
      rootfs="$out"
      dylib_dir="$rootfs/dylib"
      mkdir -p "$dylib_dir"

      is_macho() {
        file "$1" 2>/dev/null | grep -q "Mach-O"
      }

      macho_files() {
        find "$rootfs" -type f \( -perm -0100 -o -name "*.so" -o -name "*.dylib" -o -name "*.dylib.*" \) 2>/dev/null \
          | while read -r file_path; do
              if is_macho "$file_path"; then
                echo "$file_path"
              fi
            done
      }

      nix_store_deps() {
        otool -L "$1" 2>/dev/null | awk 'NR > 1 && $1 ~ "^/nix/store/" { print $1 }'
      }

      for iteration in 1 2 3 4 5 6 7 8; do
        copied=0
        for macho in $(macho_files); do
          for dep in $(nix_store_deps "$macho"); do
            dep_name="$(basename "$dep")"
            if [ ! -e "$dylib_dir/$dep_name" ] && [ -e "$dep" ]; then
              cp -L "$dep" "$dylib_dir/$dep_name"
              chmod u+w "$dylib_dir/$dep_name"
              copied=1
            fi
          done
        done
        [ "$copied" = "0" ] && break
      done

      for macho in $(macho_files); do
        rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$dylib_dir" "$macho")"

        case "$macho" in
          "$dylib_dir"/*)
            install_name_tool -id "@rpath/$(basename "$macho")" "$macho" 2>/dev/null || true
            ;;
        esac

        changed=0
        for dep in $(nix_store_deps "$macho"); do
          dep_name="$(basename "$dep")"
          if [ -e "$dylib_dir/$dep_name" ]; then
            install_name_tool -change "$dep" "@rpath/$dep_name" "$macho" 2>/dev/null || true
            changed=1
          fi
        done

        if [ "$changed" = "1" ]; then
          install_name_tool -add_rpath "@loader_path/$rel" "$macho" 2>/dev/null || true
        fi

        otool -l "$macho" 2>/dev/null | awk '
          $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
          in_rpath && $1 == "path" { print $2; in_rpath = 0 }
        ' | while read -r rpath; do
          case "$rpath" in
            /nix/store/*) install_name_tool -delete_rpath "$rpath" "$macho" 2>/dev/null || true ;;
          esac
        done

        strip -x "$macho" 2>/dev/null || true
        codesign --force --sign - "$macho" 2>/dev/null || true
      done

      echo "Auditing Darwin portable output"
      unresolved="$(
        for macho in $(macho_files); do
          otool -L "$macho" 2>/dev/null | awk -v f="$macho" 'NR > 1 && $1 ~ "^/nix/store/" { print f " -> " $1 }'
          otool -l "$macho" 2>/dev/null | awk -v f="$macho" '
            $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
            in_rpath && $1 == "path" && $2 ~ "^/nix/store/" { print f " rpath -> " $2; in_rpath = 0 }
            in_rpath && $1 == "path" { in_rpath = 0 }
          '
        done
      )"
      if [ -n "$unresolved" ]; then
        echo "$unresolved" >&2
        exit 1
      fi

      if grep -rl "/nix/store" "$rootfs/bin" "$rootfs"/releases "$rootfs"/erts-*/bin 2>/dev/null; then
        echo "release launch scripts reference /nix/store" >&2
        exit 1
      fi
    '';
  };
}
