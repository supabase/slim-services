# Repo-owned portable Nix package for the Pooler / Supavisor. The package is
# imported with the exact upstream source and dependency hashes for the
# requested release; see NIX_PORTABLE_ARTIFACT_PLAYBOOK.md for the packaging
# notes.
#
# Adapted from upstream sources/pooler/nix/package.nix (which is stale: it
# points at native/pgparser/Cargo.lock while the workspace lock lives at
# native/Cargo.lock). The pgparser NIF is a Rust cdylib built by rustler
# during mix compile; cargo dependencies are vendored via importCargoLock and
# native/pgparser/.cargo/config.toml already carries the macOS
# `-undefined dynamic_lookup` link flags rustler NIFs need.
{
  pkgs,
  runtimeNixpkgsSrc,
  serviceVersion ? "dev",
  mixDepsHash ? null,
  src ? throw "pooler requires an explicit source path",
  upstreamDockerfile ? builtins.readFile "${src}/Dockerfile",
  portableBeam ? ../../../nix/portable-beam,
}:
let
  lib = pkgs.lib;
  sourceRoot = src;
  upstreamDockerfileLines = lib.splitString "\n" upstreamDockerfile;
  upstreamDockerArg =
    name:
    let
      prefix = "ARG ${name}=";
      line = lib.findFirst (
        candidate: lib.hasPrefix prefix candidate
      ) (throw "upstream Pooler Dockerfile does not declare ${prefix}<version>") upstreamDockerfileLines;
    in
    lib.removePrefix prefix line;
  upstreamElixirVersion = upstreamDockerArg "ELIXIR_VERSION";
  upstreamOtpVersion = upstreamDockerArg "OTP_VERSION";
  elixirGeneration = lib.concatStringsSep "." (lib.take 2 (lib.splitVersion upstreamElixirVersion));
  otpGeneration = lib.head (lib.splitVersion upstreamOtpVersion);
  runtimeDefinitions = "${runtimeNixpkgsSrc}/pkgs/development/interpreters";
  erlangDefinition = "${runtimeDefinitions}/erlang/${otpGeneration}.nix";
  elixirDefinition = "${runtimeDefinitions}/elixir/${elixirGeneration}.nix";
  erlang =
    if builtins.pathExists erlangDefinition then
      let
        genericBuilder =
          versionArgs:
          import "${runtimeDefinitions}/erlang/generic-builder.nix" (
            versionArgs
            // {
              systemdSupport = false;
              wxSupport = pkgs.stdenv.isDarwin;
            }
          );
      in
      pkgs.callPackage (import erlangDefinition genericBuilder) {
        libx11 = pkgs.xorg.libX11;
        unixodbc = pkgs.unixODBC;
        wxwidgets_3_2 = pkgs.wxGTK32;
      }
    else
      throw "runtime definitions do not provide OTP ${otpGeneration} required by Pooler's upstream Dockerfile";
  baseBeamPackages = pkgs.beam.packagesWith erlang;
  beamPackages = baseBeamPackages.extend (
    _final: previous: {
      # Rebar's package-level Common Test suite is unrelated to the service
      # artifact and has a known temp-directory collision when CI builds several
      # BEAM targets concurrently. Service compilation and smoke tests stay on.
      rebar3 = previous.rebar3.overrideAttrs (_: {
        doCheck = false;
      });
    }
  );
  elixir =
    if builtins.pathExists elixirDefinition then
      beamPackages.callPackage elixirDefinition {
        inherit erlang;
        debugInfo = true;
      }
    else
      throw "runtime definitions do not provide Elixir ${elixirGeneration} required by Pooler's upstream Dockerfile";
  glibcLocalesMinimal = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [ "en_US.UTF-8/UTF-8" ];
  };
  fetchMixDeps = beamPackages.fetchMixDeps.override { inherit elixir; };
  mixRelease = beamPackages.mixRelease.override { inherit elixir fetchMixDeps; };

  pname = "supavisor";
  version = serviceVersion;

  cleanedSrc = lib.cleanSourceWith {
    src = sourceRoot;
    filter =
      path: type:
      let
        rel = lib.removePrefix (toString sourceRoot + "/") (toString path);
      in
      !(lib.hasPrefix "nix" rel)
      && !(lib.hasPrefix ".git" rel)
      && !(lib.hasPrefix "test" rel)
      && !(lib.hasPrefix "deploy" rel)
      && !(lib.hasPrefix "bench" rel)
      && !(lib.hasPrefix "docs" rel);
  };

  # crates.io /api/v1 403s curl's default UA. Remap the fetch URL only —
  # extraRegistries writes a second crates-io source and cargo rejects it.
  importCargoLock = pkgs.rustPlatform.importCargoLock.override {
    fetchurl =
      args:
      let
        url = args.url or "";
        api = "https://crates.io/api/v1/crates/";
      in
      pkgs.fetchurl (
        args
        // lib.optionalAttrs (lib.hasPrefix api url) {
          url = "https://static.crates.io/crates/" + lib.removePrefix api url;
        }
      );
  };

  cargoDeps = importCargoLock {
    lockFile = "${sourceRoot}/native/Cargo.lock";
  };

  mixDeps = fetchMixDeps {
    pname = "mix-deps-${pname}";
    src = cleanedSrc;
    inherit version;
    hash = if mixDepsHash != null then mixDepsHash else lib.fakeHash;
    mixEnv = "prod";
  };

  release = mixRelease ({
    inherit pname version;
    src = cleanedSrc;
    mixEnv = "prod";
    mixFodDeps = mixDeps;

    # bindgenHook wires libclang + the C standard header search paths that
    # pg_query's bindgen needs on Linux (darwin finds them through the system
    # toolchain; the hook is Linux-only so the darwin derivation is
    # unaffected).
    nativeBuildInputs = [
      pkgs.cargo
      pkgs.rustc
      pkgs.protobuf
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.rustPlatform.bindgenHook ];

    # Point cargo at the vendored dependency tree for the pgparser workspace.
    # The vendor copy must be writable: pg_query's build script writes its
    # generated protobuf bindings back into the crate source directory.
    preConfigure = ''
      mkdir -p native/.cargo native/pgparser/.cargo
      cat ${cargoDeps}/.cargo/config.toml >> native/.cargo/config.toml
      cat ${cargoDeps}/.cargo/config.toml >> native/pgparser/.cargo/config.toml
      cp -RL ${cargoDeps} "$PWD/cargo-vendor-writable"
      chmod -R u+w "$PWD/cargo-vendor-writable"
      # config.toml references the relative path "cargo-vendor-dir", resolved
      # against each .cargo/config.toml location.
      ln -sfn "$PWD/cargo-vendor-writable" native/pgparser/cargo-vendor-dir
      ln -sfn "$PWD/cargo-vendor-writable" native/cargo-vendor-dir
    '';

    removeCookie = false;
  });
in
{
  mix-deps = mixDeps;

  supavisor = pkgs.stdenv.mkDerivation {
    name = "${pname}-portable";
    inherit version;
    dontUnpack = true;
    dontPatchShebangs = true;
    dontStrip = true;
    dontPatchELF = true;
    nativeBuildInputs = [
      pkgs.python3
      pkgs.file
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      pkgs.patchelf
      pkgs.binutils
    ];

    buildPhase = ''
      rootfs="$out"
      mkdir -p "$rootfs"

      cp -R ${release}/. "$rootfs/"
      chmod -R u+w "$rootfs"

      rm -rf "$rootfs"/erts-*/src "$rootfs"/erts-*/doc "$rootfs"/erts-*/man \
             "$rootfs"/erts-*/include "$rootfs"/erts-*/lib/internal
      find "$rootfs/lib" -type d \( -name src -o -name include -o -name doc \) \
        -prune -exec rm -rf {} + 2>/dev/null || true
      # Unused install-time templates and the old-style OTP start script,
      # which embed build-machine paths.
      rm -f "$rootfs"/erts-*/bin/*.src "$rootfs"/erts-*/bin/start

      # Drop the makeWrapper PATH shims mixRelease adds around the release
      # scripts; the hidden .<name>-wrapped files are the real scripts.
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

      # Restore portable shebangs (the release derivation's fixup rewrites
      # them to Nix store interpreters).
      grep -rl '^#![ ]*/nix/store' "$rootfs" 2>/dev/null | while read -r script; do
        sed -i -E '1s|^#![ ]*/nix/store/[^ /]*/bin/([a-z0-9]+)( .*)?$|#!/bin/\1\2|' "$script"
      done

      envsh_count=0
      envsh=""
      for candidate in "$rootfs"/releases/*/env.sh; do
        [ -f "$candidate" ] || continue
        envsh_count=$((envsh_count + 1))
        envsh="$candidate"
      done
      [ "$envsh_count" -eq 1 ] || {
        echo "expected exactly one release env.sh, found $envsh_count" >&2
        exit 1
      }
      if mode=$(stat -c '%a' "$envsh" 2>/dev/null); then
        :
      else
        mode=$(stat -f '%Lp' "$envsh")
      fi
      envsh_tmp="$(mktemp "$envsh.tmp.XXXXXX")"
      cleanup_envsh() {
        rm -f "$envsh_tmp"
      }
      trap cleanup_envsh EXIT HUP INT TERM
      if ! awk '
        BEGIN { found = 0 }
        /^[[:space:]]*export[[:space:]]+RELEASE_DISTRIBUTION=name[[:space:]]*$/ {
          print "export RELEASE_DISTRIBUTION=\"''${RELEASE_DISTRIBUTION:-name}\""
          found++
          next
        }
        { print }
        END { if (found != 1) exit 1 }
      ' "$envsh" >"$envsh_tmp"; then
        echo "unable to patch release distribution in: $envsh" >&2
        exit 1
      fi
      chmod "$mode" "$envsh_tmp"
      mv -f "$envsh_tmp" "$envsh"
      trap - EXIT HUP INT TERM
    ''
    + lib.optionalString pkgs.stdenv.isLinux ''
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
    ''
    + lib.optionalString pkgs.stdenv.isDarwin ''
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
