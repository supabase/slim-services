# Repo-owned portable Nix package for Realtime (darwin host-native artifacts).
#
# This file lives outside sources/ so the submodule stays read-only. The
# artifact build copies services/realtime/nix/ into a temporary export of the
# submodule (NIX_PACKAGE_OVERLAY) and runs `nix-build nix/ -A realtime`.
#
# It builds the upstream mix release with ERTS included, then applies the
# portable packaging steps from NIX_PORTABLE_ARTIFACT_PLAYBOOK.md:
# - bundle every Nix-store shared library the release references (openssl for
#   the crypto NIF, ncurses/zlib for ERTS) into rootfs dylib/;
# - rewrite install names to @rpath and add @loader_path-relative rpaths;
# - ad-hoc sign every mutated Mach-O;
# - fail the build if any shipped file still references /nix/store.
#
# Profile note: `mix assets.deploy` (esbuild/tailwind dashboard assets) is
# skipped — it needs an npm dependency tree that is not worth a second FOD for
# a local-dev artifact. config/prod.exs sets no cache_static_manifest, so the
# service boots and serves /healthcheck and websockets normally; only the
# LiveDashboard UI assets 404. Same philosophy as edge-runtime's no-AI profile.
{
  pkgs ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/ac62194c3917d5f474c1a844b6fd6da2db95077d.tar.gz";
    sha256 = "0v6bd1xk8a2aal83karlvc853x44dg1n4nk08jg3dajqyy0s98np";
  }) { },
  runtimeNixpkgsSrc ? fetchTarball {
    # Runtime definitions come from a newer immutable snapshot, while builds
    # continue to use the shared package set and its established glibc floor.
    url = "https://github.com/NixOS/nixpkgs/archive/b7c2ada94fe99c15b0dbcf4d11fd7850b957a436.tar.gz";
    sha256 = "1hw875y585lkhygn09kcbmdgm58b0nb5k0d38qwlvfngprsnp2r0";
  },
  serviceVersion ? "dev",
  mixDepsHash ? null,
}:
let
  lib = pkgs.lib;
  portableBeam =
    if builtins.pathExists ./portable-beam then ./portable-beam else ../../../nix/portable-beam;
  upstreamDockerfile = builtins.readFile ../Dockerfile;
  upstreamDockerfileLines = lib.splitString "\n" upstreamDockerfile;
  upstreamDockerArg = name:
    let
      prefix = "ARG ${name}=";
      line = lib.findFirst
        (candidate: lib.hasPrefix prefix candidate)
        (throw "upstream Realtime Dockerfile does not declare ${prefix}<version>")
        upstreamDockerfileLines;
    in
    lib.removePrefix prefix line;
  upstreamElixirVersion = upstreamDockerArg "ELIXIR_VERSION";
  upstreamOtpVersion = upstreamDockerArg "OTP_VERSION";
  elixirGeneration = lib.concatStringsSep "."
    (lib.take 2 (lib.splitVersion upstreamElixirVersion));
  otpGeneration = lib.head (lib.splitVersion upstreamOtpVersion);
  runtimeDefinitions = "${runtimeNixpkgsSrc}/pkgs/development/interpreters";
  erlangDefinition = "${runtimeDefinitions}/erlang/${otpGeneration}.nix";
  elixirDefinition = "${runtimeDefinitions}/elixir/${elixirGeneration}.nix";
  erlang =
    if builtins.pathExists erlangDefinition then
      let
        genericBuilder = versionArgs:
          import "${runtimeDefinitions}/erlang/generic-builder.nix" (versionArgs // {
            # Neither service is needed by Realtime. Keeping them out of Linux
            # avoids libsystemd and GUI dependencies that raise the glibc floor.
            systemdSupport = false;
            wxSupport = pkgs.stdenv.isDarwin;
          });
      in
      pkgs.callPackage (import erlangDefinition genericBuilder) {
        # Names used by the newer runtime definition set.
        libx11 = pkgs.xorg.libX11;
        unixodbc = pkgs.unixODBC;
        wxwidgets_3_2 = pkgs.wxGTK32;
      }
    else
      throw "runtime definitions do not provide OTP ${otpGeneration} required by Realtime's upstream Dockerfile";
  derivedHashesRaw = builtins.getEnv "SLIM_NIX_DERIVED_HASHES";
  derivedHashes =
    if derivedHashesRaw == "" then { } else builtins.fromJSON derivedHashesRaw;
  beamPackages = pkgs.beam.packagesWith erlang;
  elixir =
    if builtins.pathExists elixirDefinition then
      beamPackages.callPackage elixirDefinition {
        inherit erlang;
        debugInfo = true;
      }
    else
      throw "runtime definitions do not provide Elixir ${elixirGeneration} required by Realtime's upstream Dockerfile";
  glibcLocalesMinimal = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [ "en_US.UTF-8/UTF-8" ];
  };
  fetchMixDeps = beamPackages.fetchMixDeps.override { inherit elixir; };
  mixRelease = beamPackages.mixRelease.override { inherit elixir fetchMixDeps; };

  pname = "realtime";
  version = serviceVersion;

  # rustler_precompiled normally downloads native archives while compiling a
  # dependency. That cannot happen in the release derivation's network-isolated
  # sandbox, so stage the archive while fetchMixDeps has fixed-output network
  # access and carry it into the writable dependency copy used by mixRelease.
  # Force Lumis's legacy x86_64 build so the artifact does not inherit AVX/FMA
  # requirements from the CI builder CPU.
  lumisEnvironment = lib.optionalString
    (pkgs.stdenv.isLinux && pkgs.stdenv.hostPlatform.isx86_64) ''
      export LUMIS_USE_LEGACY_ARTIFACTS=true
    '';

  # Exclude the overlay itself (and repo noise) so editing packaging files does
  # not invalidate the deps fetcher's fixed-output derivation.
  src = lib.cleanSourceWith {
    src = ../.;
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString ../. + "/") (toString path);
      in
      !(lib.hasPrefix "nix" rel)
      && !(lib.hasPrefix ".git" rel)
      && !(lib.hasPrefix "test" rel)
      && !(lib.hasPrefix "deploy" rel)
      && !(lib.hasPrefix "bench" rel);
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
    postInstall = ''
      if [ -d "$MIX_DEPS_PATH/lumis" ]; then
        export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$out/.rustler-precompiled"
        ${lumisEnvironment}
        # Compile only Lumis's required Elixir dependencies before Lumis. The
        # fetcher deliberately has no general dependency build phase.
        mix deps.compile nimble_options --no-deps-check
        mix deps.compile rustler_precompiled --no-deps-check
        mix deps.compile lumis --no-deps-check

        # Metadata embeds build paths and is only needed by publisher tasks.
        # The checked NIF archive is the sole input the release build consumes.
        rm -f "$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH"/metadata-*.exs
        archive_count="$(find "$RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH" -maxdepth 1 \
          -type f -name '*.tar.gz' | wc -l | tr -d ' ')"
        [ "$archive_count" = 1 ] || {
          echo "expected exactly one cached Lumis NIF archive, found $archive_count" >&2
          exit 1
        }
      fi
    '';
  };

  release = mixRelease {
    inherit pname version src;
    mixEnv = "prod";
    mixFodDeps = mixDeps;
    preConfigure = ''
      if [ -d "$MIX_DEPS_PATH/.rustler-precompiled" ]; then
        export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH="$MIX_DEPS_PATH/.rustler-precompiled"
        ${lumisEnvironment}
      fi
    '';

    # The release includes ERTS by default; keep the generated start scripts.
    removeCookie = false;
  };
in
{
  mix-deps = mixDeps;

  realtime = pkgs.stdenv.mkDerivation {
    name = "${pname}-portable";
    inherit version;
    dontUnpack = true;
    dontPatchShebangs = true;
    dontStrip = true;
    nativeBuildInputs = [
      pkgs.python3
      pkgs.file
    ] ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf pkgs.binutils ];

    buildPhase = ''
      rootfs="$out"
      mkdir -p "$rootfs"

      # The mix release tree is the artifact: bin/realtime, bin/server,
      # bin/migrate (rel overlays), erts-*/, lib/, releases/.
      cp -R ${release}/. "$rootfs/"
      chmod -R u+w "$rootfs"

      # Trim BEAM release tooling that never runs in the artifact (mirrors
      # scripts/prune-beam-release.sh for the Docker artifact).
      rm -rf "$rootfs"/erts-*/src "$rootfs"/erts-*/doc "$rootfs"/erts-*/man \
             "$rootfs"/erts-*/include "$rootfs"/erts-*/lib/internal
      find "$rootfs/lib" -type d \( -name src -o -name include -o -name doc \) \
        -prune -exec rm -rf {} + 2>/dev/null || true
      # Unused install-time templates and the old-style OTP start script,
      # which embed build-machine paths (mix releases launch via bin/<name>
      # -> erl -> erlexec, all relocatable).
      rm -f "$rootfs"/erts-*/bin/*.src "$rootfs"/erts-*/bin/start

      # Drop the makeWrapper PATH shims mixRelease adds around the release
      # scripts (they inject Nix store gawk/grep/sed; macOS ships all the
      # POSIX tools the scripts use). The hidden .<name>-wrapped files are
      # the real release scripts.
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

      # Restore portable shebangs: the release derivation's fixup rewrites
      # script shebangs to Nix store interpreters, which must not ship.
      grep -rl '^#![ ]*/nix/store' "$rootfs" 2>/dev/null | while read -r script; do
        sed -i -E '1s|^#![ ]*/nix/store/[^ /]*/bin/([a-z0-9]+)( .*)?$|#!/bin/\1\2|' "$script"
      done
    '' + lib.optionalString pkgs.stdenv.isLinux ''
      # Shared BEAM fixup bundles the matching glibc family, relocates the
      # non-glibc closure, wraps dynamic ERTS/port ELFs, and audits with the
      # bundled loader. Darwin remains on the unchanged branch below.
      export PORTABLE_BEAM_ROOTFS="$out"
      export PORTABLE_BEAM_GLIBC_LIB="${pkgs.glibc}/lib"
      export PORTABLE_BEAM_GLIBC_SRC="${pkgs.glibc.src}"
      export PORTABLE_BEAM_COMPILER_SRC="${pkgs.stdenv.cc.cc.src}"
      export PORTABLE_BEAM_TZDATA="${pkgs.tzdata}/share/zoneinfo"
      export PORTABLE_BEAM_TZDATA_SRC="${lib.head pkgs.tzdata.srcs}"
      export PORTABLE_BEAM_LOCALE_LIB="${glibcLocalesMinimal}/lib/locale"
      export PORTABLE_BEAM_LAUNCHER="${portableBeam}/beam-launcher.sh"
      ${builtins.readFile "${portableBeam}/beam-linux-fixup.sh"}
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

      # 1. Complete the dylib closure: copy every /nix/store dylib referenced
      # by any shipped Mach-O (and transitively by the copies) into dylib/.
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

      # 2. Rewrite every Mach-O: /nix/store deps -> @rpath/<name>, plus an
      # @loader_path-relative rpath pointing at dylib/. Then strip local
      # symbols and ad-hoc sign (signature is invalidated by the rewrite).
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

        # Delete any absolute Nix store rpaths left by the toolchain.
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

      # 3. Audit: fail the build if any shipped Mach-O still references the
      # Nix store (load commands or rpaths).
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

      # 4. Fail loudly if any launch-path text file still references the
      # Nix store (bin/, releases/, erts bin — the scripts that actually run
      # on the host).
      if grep -rl "/nix/store" "$rootfs/bin" "$rootfs"/releases "$rootfs"/erts-*/bin 2>/dev/null; then
        echo "release launch scripts reference /nix/store" >&2
        exit 1
      fi
    '';
  };
}
