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
# - Pins: everything builds from the shared 25.05 pin so shipped binaries
#   link the same glibc floor as the other services (the distroless
#   base-debian13 runtime has glibc 2.41; nixos-unstable's 2.42 symbols broke
#   the derived image). Only the Rust toolchain comes from the unstable pin —
#   the rustler 0.37 crates require rustc >= 1.91 and 25.05 ships 1.86;
#   rustc's output is linked by the 25.05 stdenv cc, so the glibc floor is
#   unaffected. Elixir is 1.18.4 (Docker builder uses 1.19.5; mix.exs allows
#   `~> 1.4`).
{
  pkgs ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/ac62194c3917d5f474c1a844b6fd6da2db95077d.tar.gz";
    sha256 = "0v6bd1xk8a2aal83karlvc853x44dg1n4nk08jg3dajqyy0s98np";
  }) { },
  pkgsRust ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/d407951447dcd00442e97087bf374aad70c04cea.tar.gz";
    sha256 = "1jgfnvi57n79zsfljh2i4b77yj6wh028z4r3wf223am8wznzqbzj";
  }) { },
  serviceVersion ? null,
  mixDepsHash ? null,
  explorerNifHash ? null,
  sqlFmtNifHash ? null,
}:
let
  lib = pkgs.lib;
  derivedHashesRaw = builtins.getEnv "SLIM_NIX_DERIVED_HASHES";
  derivedHashes =
    if derivedHashesRaw == "" then { } else builtins.fromJSON derivedHashesRaw;
  beamPackages = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_27;
  elixir = beamPackages.elixir_1_18;
  fetchMixDeps = beamPackages.fetchMixDeps.override { inherit elixir; };
  mixRelease = beamPackages.mixRelease.override { inherit elixir fetchMixDeps; };

  pname = "logflare";
  version =
    if serviceVersion == null then
      lib.removeSuffix "\n" (builtins.readFile ../VERSION)
    else
      serviceVersion;

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

  # Mix writes a stable textual lockfile format. Resolve the exact Hex package
  # versions from the checked-out release so their precompiled NIF asset names
  # advance with future releases instead of requiring a packaging edit.
  lockedHexVersion = package:
    let
      marker = "\"${package}\": {:hex, :${package}, \"";
      parts = lib.splitString marker (builtins.readFile ../mix.lock);
    in
    if builtins.length parts != 2 then
      throw "could not resolve ${package} from mix.lock"
    else
      builtins.head (lib.splitString "\"" (builtins.elemAt parts 1));

  explorerVersion = lockedHexVersion "explorer";
  sqlFmtVersion = lockedHexVersion "sql_fmt";

  # Pinned rustler_precompiled artifacts per target (NIF 2.15, the variant
  # resolved under OTP 27).
  rustlerTarget = {
    "aarch64-darwin" = "aarch64-apple-darwin";
    "aarch64-linux" = "aarch64-unknown-linux-gnu";
    "x86_64-linux" = "x86_64-unknown-linux-gnu";
  }.${pkgs.stdenv.hostPlatform.system}
    or (throw "no rustler_precompiled pin for ${pkgs.stdenv.hostPlatform.system}");

  explorerNifName = "libexplorer-v${explorerVersion}-nif-2.15-${rustlerTarget}.so.tar.gz";
  sqlFmtNifName = "libsql_fmt_nif-v${sqlFmtVersion}-nif-2.15-${rustlerTarget}.so.tar.gz";

  explorerNif = pkgs.fetchurl {
    url = "https://github.com/elixir-explorer/explorer/releases/download/v${explorerVersion}/${explorerNifName}";
    hash =
      if explorerNifHash != null then
        explorerNifHash
      else
        derivedHashes.explorer_nif_hash or lib.fakeHash;
  };
  sqlFmtNif = pkgs.fetchurl {
    url = "https://github.com/akoutmos/sql_fmt/releases/download/v${sqlFmtVersion}/${sqlFmtNifName}";
    hash =
      if sqlFmtNifHash != null then
        sqlFmtNifHash
      else
        derivedHashes.sql_fmt_nif_hash or lib.fakeHash;
  };

  mixDeps = fetchMixDeps {
    pname = "mix-deps-${pname}";
    inherit version src;
    hash =
      if mixDepsHash != null then
        mixDepsHash
      else
        derivedHashes.mix_deps_hash or lib.fakeHash;
    mixEnv = "prod";
  };

  release = mixRelease {
    inherit pname version src;
    mixEnv = "prod";
    mixFodDeps = mixDeps;

    nativeBuildInputs = [
      pkgsRust.cargo
      pkgsRust.rustc
    ];

    preConfigure = ''
      # rustler_precompiled checks its cache before hitting the network;
      # seed it with the pinned NIF tarballs for this target (both basedir
      # layouts).
      export HOME="$TMPDIR/home"
      for cache in "$HOME/Library/Caches/rustler_precompiled/precompiled_nifs" \
                   "$HOME/.cache/rustler_precompiled/precompiled_nifs"; do
        mkdir -p "$cache"
        cp ${explorerNif} "$cache/${explorerNifName}"
        cp ${sqlFmtNif} "$cache/${sqlFmtNifName}"
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
  mix-deps = mixDeps;
  explorer-nif = explorerNif;
  sql-fmt-nif = sqlFmtNif;

  logflare = pkgs.stdenv.mkDerivation {
    name = "${pname}-portable";
    inherit version;
    dontUnpack = true;
    dontPatchShebangs = true;
    dontStrip = true;
    nativeBuildInputs = [
      pkgs.python3
      pkgs.file
    ] ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];

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

      # nixpkgs patches OTP's disksup to spawn its port shell via an absolute
      # Nix store bash path (compiled into disksup.beam, invisible to the
      # binary audits). That path does not exist off the build machine, so
      # disksup crash-loops and takes os_mon down. memsup/cpu_sup use the
      # release's own priv/bin ports and keep working; disk metrics are not
      # needed for local dev.
      for vmargs in "$rootfs"/releases/*/vm.args; do
        [ -f "$vmargs" ] || continue
        printf '\n## Portable artifact: disksup would spawn a Nix store bash (see nix package)\n-os_mon start_disksup false\n' >> "$vmargs"
      done
    '';

    postFixup = ''
      rootfs="$out"

      grep -rl '^#![ ]*/nix/store' "$rootfs" 2>/dev/null | while read -r script; do
        sed -i -E '1s|^#![ ]*/nix/store/[^ /]*/bin/([a-z0-9]+)( .*)?$|#!/bin/\1\2|' "$script"
      done
    '' + lib.optionalString pkgs.stdenv.isLinux ''
      # Linux half of the portable playbook: bundle every non-glibc shared
      # library into dylib/, point every ELF at it with $ORIGIN-relative
      # rpaths and at the host's dynamic loader, then audit with ldd.
      rootfs="$out"
      dylib_dir="$rootfs/dylib"
      mkdir -p "$dylib_dir"
      # Runtime side-data: bundle zoneinfo and point TZDIR at it from the
      # release env.sh. Minimal hosts may lack /usr/share/zoneinfo and glibc
      # silently falls back to UTC. NSS/gconv/locale need NO bundling at the
      # glibc 2.39 floor (nss_files/nss_dns are compiled into libc >= 2.34,
      # gconv ships with the host libc, C.UTF-8 is built in >= 2.35) — see
      # docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md.
      mkdir -p "$rootfs/share"
      cp -RL ${pkgs.tzdata}/share/zoneinfo "$rootfs/share/zoneinfo"
      chmod -R u+w "$rootfs/share/zoneinfo"
      # posix/ duplicates the top-level zones; right/ is the TAI variant.
      rm -rf "$rootfs/share/zoneinfo/posix" "$rootfs/share/zoneinfo/right"
      for envsh in "$rootfs"/releases/*/env.sh; do
        [ -f "$envsh" ] || continue
        {
          printf '\n## Portable artifact: prefer bundled zoneinfo (see nix package)\n'
          printf 'if [ -z "''${TZDIR:-}" ] && [ -d "$RELEASE_ROOT/share/zoneinfo" ]; then\n'
          printf '  export TZDIR="$RELEASE_ROOT/share/zoneinfo"\nfi\n'
        } >> "$envsh"
      done

      case "$(uname -m)" in
        aarch64) interp="/lib/ld-linux-aarch64.so.1" ;;
        x86_64) interp="/lib64/ld-linux-x86-64.so.2" ;;
        *) echo "unsupported linux arch $(uname -m)" >&2; exit 1 ;;
      esac

      is_elf() {
        file "$1" 2>/dev/null | grep -q "ELF"
      }

      elf_files() {
        find "$rootfs" -type f \( -perm -0100 -o -name "*.so" -o -name "*.so.*" \) 2>/dev/null \
          | while read -r file_path; do
              if is_elf "$file_path"; then
                echo "$file_path"
              fi
            done
      }

      # The glibc family resolves from the host (contract item 3).
      should_exclude() {
        case "$1" in
          libc.so*|libc-*.so*|ld-linux*.so*|libdl.so*|libpthread.so*|libm.so*|libresolv.so*|librt.so*)
            return 0 ;;
          *)
            return 1 ;;
        esac
      }

      nix_store_deps() {
        ldd "$1" 2>/dev/null | awk '/=> \/nix\/store/ { print $3 } $1 ~ "^/nix/store" { print $1 }'
      }

      # 1. Complete the closure before any patching (ldd still resolves the
      # original Nix rpaths at this point).
      for iteration in 1 2 3 4 5 6 7 8; do
        copied=0
        for elf in $(elf_files) "$dylib_dir"/*; do
          [ -f "$elf" ] || continue
          for dep in $(nix_store_deps "$elf"); do
            dep_name="$(basename "$dep")"
            should_exclude "$dep_name" && continue
            if [ ! -e "$dylib_dir/$dep_name" ] && [ -e "$dep" ]; then
              cp -L "$dep" "$dylib_dir/$dep_name"
              chmod u+w "$dylib_dir/$dep_name"
              copied=1
            fi
          done
        done
        [ "$copied" = "0" ] && break
      done

      # 2. Patch: system loader for executables, $ORIGIN-relative rpath to
      # dylib/ for everything, then strip.
      for elf in $(elf_files); do
        rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$dylib_dir" "$elf")"
        if patchelf --print-interpreter "$elf" >/dev/null 2>&1; then
          patchelf --set-interpreter "$interp" "$elf" 2>/dev/null || true
        fi
        patchelf --set-rpath "\$ORIGIN/$rel" "$elf" 2>/dev/null || true
        strip --strip-unneeded "$elf" 2>/dev/null || true
      done

      # 3. Audit: no unresolved deps, no Nix store references (the loader
      # itself and the glibc family are expected from the host and resolve
      # to the build sandbox's glibc here).
      echo "Auditing Linux portable output"
      unresolved="$(
        for elf in $(elf_files); do
          ldd "$elf" 2>/dev/null | awk -v file="$elf" -v rootfs="$rootfs" '
            /not found/ { print file " -> " $0; next }
            /=> \// { path = $3 }
            path ~ "^/nix/store/" && index(path, rootfs "/") != 1 {
              name = path
              sub(/^.*\//, "", name)
              if (name !~ /^(ld-linux.*|libc\.so.*|libc-.*\.so.*|libdl\.so.*|libpthread\.so.*|libm\.so.*|libresolv\.so.*|librt\.so.*)$/) {
                print file " -> " path
              }
              path = ""
            }
          '
        done
      )"
      if [ -n "$unresolved" ]; then
        echo "$unresolved" >&2
        exit 1
      fi
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
