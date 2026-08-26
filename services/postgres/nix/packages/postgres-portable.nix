{
  lib,
  stdenv,
  writeTextFile,
  patchelf,
  psql_17_cli,
}:
let
  configDir = ./cli-config;

  # slim-services overlay — shared config recipe. Upstream's hand-written CLI
  # template (nix/packages/cli-config/) drifted from the docker.io image's
  # real configuration (ansible/files/), which produced a stream of parity
  # bugs (empty supautils allowlist, missing extension custom scripts,
  # missing conf.d, no replication slots, libc-C collation…). Instead of
  # patching each gap, the bundle now consumes the SAME files the docker.io
  # image is built from, with the SAME edits Dockerfile-supabase applies,
  # so the two cannot drift; nix/packages/local-dev.conf is the single,
  # complete list of deliberate divergences. Drop this once upstream's
  # cli-config assembles from ansible/files/ itself.
  ansibleConfig = ../../ansible/files/postgresql_config;
  supautilsConf = ../../ansible/files/postgresql_config/supautils.conf.j2;
  extensionCustomScripts = ../../ansible/files/postgresql_extension_custom_scripts;
  localDevConf = ./local-dev.conf;
  stageSharedConfig = ./stage-shared-config.sh;

  receipt = writeTextFile {
    name = "cli-receipt";
    destination = "/receipt.json";
    text = builtins.toJSON {
      variant = "cli";
      psql-version = psql_17_cli.bin.version;
      # slim-services overlay: the full PG17 extension set (see postgres.nix).
      extensions = [
        "rum"
        "pgroonga"
        "index_advisor"
        "wal2json"
        "pgmq"
        "pg_repack"
        "safeupdate"
        "plpgsql_check"
        "pgjwt"
        "pgaudit"
        "postgis"
        "pgrouting"
        "pgtap"
        "pg_cron"
        "http"
        "plan_filter"
        "pg_net"
        "pg_hashids"
        "pgsodium"
        "pg_graphql"
        "pg_stat_monitor"
        "pg_jsonschema"
        "pg_partman"
        "vector"
        "supabase_vault"
        "hypopg"
        "pg_tle"
        "wrappers"
        "supautils"
      ];
      receipt-version = "1";
    };
  };

  migrationBundle = stdenv.mkDerivation {
    name = "cli-migration-bundle";
    src = ../../migrations/db;
    dontPatchShebangs = true;
    installPhase = ''
      mkdir -p $out/share/supabase-cli/migrations
      cp -r init-scripts $out/share/supabase-cli/migrations/
      cp -r migrations $out/share/supabase-cli/migrations/
      cp migrate.sh $out/share/supabase-cli/migrations/
      chmod +x $out/share/supabase-cli/migrations/migrate.sh

      # Add pgbouncer schema (same as Docker build does)
      cp ${../../ansible/files/pgbouncer_config/pgbouncer_auth_schema.sql} \
         $out/share/supabase-cli/migrations/init-scripts/00-schema.sql

      # Add pg_stat_statements extension (same as Docker build does)
      cp ${../../ansible/files/stat_extension.sql} \
         $out/share/supabase-cli/migrations/migrations/00-extension.sql
    '';
  };

  configBundle = stdenv.mkDerivation {
    name = "cli-config-bundle";
    src = configDir;
    dontPatchShebangs = true;
    installPhase = ''
      mkdir -p $out/share/supabase-cli/config/conf.d
      mkdir -p $out/share/supabase-cli/bin
      mkdir -p $out/share/supabase-cli/extension-custom-scripts
      cfg=$out/share/supabase-cli/config

      # These .j2 files are plain postgresql.conf syntax today (the docker.io
      # Dockerfile also consumes them raw); refuse actual Jinja templating.
      for j2 in ${ansibleConfig}/postgresql.conf.j2 \
                ${ansibleConfig}/pg_hba.conf.j2 \
                ${ansibleConfig}/pg_ident.conf.j2 \
                ${supautilsConf}; do
        if grep -q '{{\|{%' "$j2"; then
          echo "$j2 contains Jinja templating; cannot consume verbatim" >&2
          exit 1
        fi
      done

      # postgresql.conf: the docker.io config, with (a) the exact edits
      # Dockerfile-supabase's "Configure PostgreSQL settings" and PG17 steps
      # apply, and (b) mechanical relocation only — absolute /etc include
      # targets become PGDATA-relative names (stage-shared-config.sh stages
      # the siblings), and the file-location GUCs are commented out so they
      # follow `postgres -D $PGDATA`. Nothing here changes a VALUE.
      conf=$cfg/postgresql.conf.template
      install -m 0644 ${ansibleConfig}/postgresql.conf.j2 $conf
      sed -i \
        -e "s|^#session_preload_libraries = .*|session_preload_libraries = 'supautils'|" \
        -e "s|#include = '/etc/postgresql-custom/supautils.conf'|include = 'supautils.conf'|" \
        -e "s|#include = '/etc/postgresql-custom/wal-g.conf'|include = 'wal-g.conf'|" \
        -e "s|include = '/etc/postgresql-custom/read-replica.conf'|include = 'read-replica.conf'|" \
        -e "s|include = '/etc/postgresql/logging.conf'|include = 'logging.conf'|" \
        -e "s|include_dir = '/etc/postgresql-custom/conf.d'|include_dir = 'conf.d'|" \
        -e "s|^data_directory = |#data_directory = |" \
        -e "s|^hba_file = |#hba_file = |" \
        -e "s|^ident_file = |#ident_file = |" \
        -e "s/ timescaledb,//g" \
        -e "s/ plv8,//g" \
        -e "s/db_user_namespace = off/#db_user_namespace = off/g" \
        $conf
      for want in \
        "^session_preload_libraries = 'supautils'" \
        "^include = 'supautils.conf'" \
        "^include = 'wal-g.conf'" \
        "^include = 'read-replica.conf'" \
        "^include = 'logging.conf'" \
        "^include_dir = 'conf.d'" \
        "^#data_directory = " \
        "^#hba_file = " \
        "^#ident_file = " \
        "^#db_user_namespace = "; do
        grep -q "$want" $conf || {
          echo "shared-recipe anchor missing after edits: $want" >&2
          exit 1
        }
      done
      if grep "^shared_preload_libraries" $conf | grep -q "timescaledb\|plv8"; then
        echo "PG17-incompatible extension left in shared_preload_libraries" >&2
        exit 1
      fi
      grep "^shared_preload_libraries" $conf | grep -q "pgaudit" || {
        echo "expected the full docker.io shared_preload_libraries set" >&2
        exit 1
      }

      # The single divergence file — the complete slim-vs-docker.io delta.
      { echo ""; cat ${localDevConf}; } >> $conf

      # Include siblings, staged into PGDATA at first boot by
      # stage-shared-config.sh (sourced from the init script, see below).
      install -m 0644 ${ansibleConfig}/postgresql-stdout-log.conf $cfg/logging.conf
      install -m 0644 ${ansibleConfig}/custom_walg.conf $cfg/wal-g.conf
      install -m 0644 ${ansibleConfig}/custom_read_replica.conf $cfg/read-replica.conf
      install -m 0644 ${ansibleConfig}/conf.d/*.conf $cfg/conf.d/
      # Same PG17 strip Dockerfile-supabase applies to supautils.conf.
      sed 's/ timescaledb,//g; s/ plv8,//g' ${supautilsConf} > $cfg/supautils.conf
      grep -q "^supautils.privileged_extensions = " $cfg/supautils.conf || {
        echo "supautils.conf lost its allowlist" >&2
        exit 1
      }

      # pg_hba/pg_ident: docker.io's files; the ONE divergence is
      # `peer map=supabase_map` -> `trust`, because the map assumes the
      # docker.io image's OS users (postgres/root/ubuntu) and neither the
      # distroless image (uid 65532) nor a host runtime has them — the map
      # resolves those users to full role access anyway, so local trust is
      # the same effective posture.
      install -m 0644 ${ansibleConfig}/pg_hba.conf.j2 $cfg/pg_hba.conf.template
      sed -i "s|peer map=supabase_map|trust|" $cfg/pg_hba.conf.template
      if grep -q "supabase_map" $cfg/pg_hba.conf.template; then
        echo "unexpected supabase_map reference left in pg_hba" >&2
        exit 1
      fi
      install -m 0644 ${ansibleConfig}/pg_ident.conf.j2 $cfg/pg_ident.conf.template

      # The extension custom scripts (before/after CREATE EXTENSION grant and
      # ownership hooks) — the docker.io image ships these at
      # /etc/postgresql-custom/extension-custom-scripts.
      cp -R ${extensionCustomScripts}/. $out/share/supabase-cli/extension-custom-scripts/

      cp pgsodium_getkey.sh $cfg/
      install -m 0644 ${stageSharedConfig} $out/share/supabase-cli/bin/stage-shared-config.sh
      cp supabase-postgres-init.sh $out/share/supabase-cli/bin/
      chmod +x $cfg/pgsodium_getkey.sh
      chmod +x $out/share/supabase-cli/bin/supabase-postgres-init.sh

      # Patch the init script (three anchored edits; each asserted below):
      #  1. source stage-shared-config.sh after the config templates are
      #     copied into PGDATA;
      #  2. initdb with the docker.io image's locale flags
      #     (POSTGRES_INITDB_ARGS there: --allow-group-access
      #     --locale-provider=icu --encoding=UTF-8 --icu-locale=en_US.UTF-8);
      #  3. export LOCALE_ARCHIVE from the bundled minimal glibc locale
      #     archive (Linux) so lc_* = en_US.UTF-8 resolves.
      init=$out/share/supabase-cli/bin/supabase-postgres-init.sh
      sed -i \
        -e '/pg_ident.conf.template/a\	. "$BUNDLE_DIR/share/supabase-cli/bin/stage-shared-config.sh"' \
        -e 's|--encoding=UTF8 \\|--encoding=UTF-8 \\|' \
        -e 's|--locale=C \\|--locale-provider=icu --icu-locale=en_US.UTF-8 --allow-group-access \\|' \
        -e '/^PGBIN=/a\if [ -f "$BUNDLE_DIR/lib/locale/locale-archive" ]; then export LOCALE_ARCHIVE="''${LOCALE_ARCHIVE:-$BUNDLE_DIR/lib/locale/locale-archive}"; fi' \
        $init
      for want in "stage-shared-config.sh" "icu-locale=en_US.UTF-8" "LOCALE_ARCHIVE"; do
        grep -q "$want" $init || {
          echo "init-script patch anchor missing: $want" >&2
          exit 1
        }
      done
      bash -n $init
    '';
  };
in
stdenv.mkDerivation {
  name = "psql_17_cli_portable";
  version = psql_17_cli.bin.version;

  dontUnpack = true;
  dontPatchShebangs = true;
  nativeBuildInputs = lib.optionals stdenv.isLinux [ patchelf ];

  buildPhase = ''
    mkdir -p $out/bin $out/lib $out/share

    # List of PostgreSQL binaries to include in the Supabase CLI bundle
    binaries="postgres pg_config pg_ctl initdb psql pg_dump pg_restore createdb dropdb pg_isready"

    # Helper function to check if a library should be excluded (system libraries)
    should_exclude_library() {
      local libname="$1"
      # Exclude core system libraries that must come from the host system
      # These libraries are tightly coupled to the kernel and system configuration
      case "$libname" in
        libc.so*|libc-*.so*|ld-linux*.so*|libdl.so*|libpthread.so*|libm.so*|libresolv.so*|librt.so*)
          return 0  # Exclude
          ;;
        *)
          return 1  # Include
          ;;
      esac
    }

    # Helper function to get dependencies from a binary based on platform
    # Returns empty string if no dependencies found (which is valid - not an error)
    copy_deps_from_binary() {
      local bin="$1"
      local result=""
      if [ "$(uname)" = "Darwin" ]; then
        result=$(otool -L "$bin" 2>/dev/null | grep /nix/store | awk '{print $1}' | awk 'NF') || result=""
      else
        result=$(ldd "$bin" 2>/dev/null | grep /nix/store | awk '{print $3}' | awk 'NF') || result=""
      fi
      echo "$result"
    }

    # Helper function to get the library file pattern based on platform
    get_lib_pattern() {
      if [ "$(uname)" = "Darwin" ]; then
        echo "*.dylib*"
      else
        echo "*.so*"
      fi
    }

    # Function to recursively resolve symlinks and find actual binaries
    # This is needed because PostgreSQL binaries in Nix are often wrapped scripts
    # that reference the actual binary via .wrapped files. We need to extract
    # the actual binary (not the wrapper script) for the Supabase CLI bundle.
    resolve_binary() {
      local path="$1"
      local max_depth=10
      local depth=0

      while [ $depth -lt $max_depth ]; do
        if [ -f "$path" ] && ! [ -L "$path" ]; then
          # Check if it's a script or binary
          if file "$path" | grep -q "script"; then
            # It's a wrapper script, look for the wrapped binary
            local wrapped=$(grep -o '/nix/store/[^"]*-wrapped[^"]*' "$path" | head -1)
            if [ -n "$wrapped" ] && [ -f "$wrapped" ]; then
              path="$wrapped"
              depth=$((depth + 1))
              continue
            fi
          fi
          echo "$path"
          return 0
        elif [ -L "$path" ]; then
          path=$(readlink -f "$path")
          depth=$((depth + 1))
        else
          return 1
        fi
      done
      return 1
    }

    # Copy binaries (resolve all wrappers to get actual binaries)
    for bin in $binaries; do
      if [ -f ${psql_17_cli.bin}/bin/$bin ] || [ -L ${psql_17_cli.bin}/bin/$bin ]; then
        actual_binary=$(resolve_binary ${psql_17_cli.bin}/bin/$bin)
        if [ -n "$actual_binary" ] && [ -f "$actual_binary" ]; then
          cp "$actual_binary" $out/bin/.$bin-wrapped 2>/dev/null || true
        fi
      fi
    done

    # Copy all shared libraries from PostgreSQL
    if [ -d ${psql_17_cli.bin}/lib ]; then
      cp -rL ${psql_17_cli.bin}/lib/* $out/lib/ 2>/dev/null || true
    fi

    # Copy all runtime dependencies (shared libraries) from binaries
    for bin in $out/bin/.*-wrapped; do
      if [ -f "$bin" ]; then
        deps=$(copy_deps_from_binary "$bin")
        if [ -n "$deps" ]; then
          echo "$deps" | while read dep; do
            if [ -f "$dep" ]; then
              libname=$(basename "$dep")
              if ! should_exclude_library "$libname"; then
                cp "$dep" $out/lib/ 2>/dev/null || true
              else
                echo "Skipping system library: $libname"
              fi
            fi
          done
        fi
      fi
    done

    # Second pass: recursively check libraries for their dependencies (e.g., libicuuc -> libicudata -> libcharset)
    # Run multiple iterations until no new libraries are found
    lib_pattern=$(get_lib_pattern)
    for iteration in {1..5}; do
      before_count=$(ls $out/lib/$lib_pattern 2>/dev/null | wc -l || echo "0")
      # Use find instead of glob to avoid bash errors when pattern doesn't match
      libs=$(find $out/lib -name "$lib_pattern" -type f 2>/dev/null || true)
      if [ -n "$libs" ]; then
        echo "$libs" | while read lib; do
          if [ -f "$lib" ]; then
            deps=$(copy_deps_from_binary "$lib")
            if [ -n "$deps" ]; then
              echo "$deps" | while read dep; do
                if [ -f "$dep" ]; then
                  libname=$(basename "$dep")
                  if [ ! -f "$out/lib/$libname" ]; then
                    if ! should_exclude_library "$libname"; then
                      echo "Iteration $iteration: Copying transitive dependency $libname"
                      cp "$dep" $out/lib/ 2>/dev/null || true
                    else
                      echo "Iteration $iteration: Skipping system library $libname"
                    fi
                  fi
                fi
              done
            fi
          fi
        done
      fi
      after_count=$(ls $out/lib/$lib_pattern 2>/dev/null | wc -l || echo "0")
      if [ "$before_count" -eq "$after_count" ]; then
        echo "No new dependencies found after $iteration iterations"
        break
      fi
    done

    # slim-services overlay: the darwin closure contains TWO libiconv
    # FAMILIES at once — GNU libiconv-1.x (exports _libiconv; libidn2-2.3.8
    # and gettext-0.25.1 import that) and the Apple SDK libiconv (exports
    # _iconv; libidn2-2.3.7 and gettext-0.21.1 import that) — and both ship
    # dylibs named libiconv(.2).dylib/libcharset.1.dylib. The flat basename
    # copies above let whichever was traversed last clobber the other, and
    # NO single file can satisfy both symbol sets. Ship the GNU library
    # under a NON-COLLIDING name: the bin wrappers set DYLD_LIBRARY_PATH,
    # which redirects ANY matching leafname into lib/ (even /usr/lib
    # references), so no bundled file may be named libiconv*/libcharset*.
    # postFixup routes GNU-family references to the bundled copy and
    # Apple-family references to the OS copies in the dyld shared cache.
    if [ "$(uname)" = "Darwin" ]; then
      rm -f $out/lib/libiconv* $out/lib/libcharset*
      for macho in $out/bin/.* $out/bin/* $out/lib/*; do
        [ -f "$macho" ] || continue
        file "$macho" 2>/dev/null | grep -q "Mach-O" || continue
        # Phases run under pipefail: a no-match grep must not abort the
        # build, so capture with an explicit fallback instead of piping
        # straight into the loop.
        iconv_refs="$(otool -L "$macho" 2>/dev/null | awk '{print $1}' | grep '^/nix/store/.*libiconv' || true)"
        [ -n "$iconv_refs" ] || continue
        echo "$iconv_refs" | while read -r dep; do
          if [ ! -e "$out/lib/libgnuiconv.2.dylib" ] && nm -gU "$dep" 2>/dev/null | grep -qw _libiconv; then
            echo "Bundling GNU libiconv from $dep as libgnuiconv.2.dylib"
            cp -L "$dep" "$out/lib/libgnuiconv.2.dylib"
            chmod u+w "$out/lib/libgnuiconv.2.dylib"
          fi
        done
      done
    fi

    # Copy share directory
    if [ -d ${psql_17_cli.bin}/share ]; then
      cp -rL ${psql_17_cli.bin}/share/* $out/share/ 2>/dev/null || true
    fi

    # Add config templates and initialization script
    mkdir -p $out/share/supabase-cli/config
    mkdir -p $out/share/supabase-cli/bin
    cp ${configBundle}/share/supabase-cli/config/* $out/share/supabase-cli/config/
    cp ${configBundle}/share/supabase-cli/bin/* $out/share/supabase-cli/bin/

    # Add migration files
    cp -r ${migrationBundle}/share/supabase-cli/migrations $out/share/supabase-cli/

    # Add receipt
    cp ${receipt}/receipt.json $out/cli-receipt.json
  '';

  installPhase = ''
        # Create wrapper scripts for Supabase CLI that set up library paths
        for bin in $binaries; do
          if [ -f $out/bin/.$bin-wrapped ]; then
            cat > $out/bin/$bin << 'WRAPPER_EOF'
    #!/bin/bash
    SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
    export NIX_PGLIBDIR="$SCRIPT_DIR/../lib"

    # For Linux, set LD_LIBRARY_PATH to include bundled libraries
    if [ "$(uname)" = "Linux" ]; then
      export LD_LIBRARY_PATH="$SCRIPT_DIR/../lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi

    # For macOS, set DYLD_LIBRARY_PATH
    if [ "$(uname)" = "Darwin" ]; then
      export DYLD_LIBRARY_PATH="$SCRIPT_DIR/../lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    fi

    exec "$SCRIPT_DIR/.BINNAME-wrapped" "$@"
    WRAPPER_EOF
            sed -i "s/BINNAME/$bin/g" $out/bin/$bin
            chmod +x $out/bin/$bin
          fi
        done
  '';

  postFixup =
    lib.optionalString stdenv.isLinux ''
      # Determine the correct interpreter path based on architecture
      if [ "$(uname -m)" = "x86_64" ]; then
        INTERP="/lib64/ld-linux-x86-64.so.2"
      elif [ "$(uname -m)" = "aarch64" ]; then
        INTERP="/lib/ld-linux-aarch64.so.1"
      else
        echo "ERROR: Unsupported architecture $(uname -m)"
        exit 1
      fi

      # slim-services overlay: the pgrx extensions ship unstripped (wrappers
      # alone is 128 MiB; ~30 MiB stripped). Strip BEFORE patchelf — GNU
      # strip can corrupt binaries whose section layout patchelf already
      # rewrote, the reverse order is safe.
      for elf in $out/bin/.*-wrapped $out/lib/*.so*; do
        [ -f "$elf" ] || continue
        [ -L "$elf" ] && continue
        file "$elf" | grep -q ELF || continue
        strip --strip-unneeded "$elf" 2>/dev/null || true
      done

      # On Linux, patch binaries to use system interpreter and relative library paths
      # This makes the bundle portable across Linux systems for Supabase CLI
      for bin in $out/bin/.*-wrapped; do
        if [ -f "$bin" ] && file "$bin" | grep -q ELF; then
          echo "Patching RPATH and interpreter for $bin"
          # Set interpreter to system dynamic linker for portability
          patchelf --set-interpreter "$INTERP" "$bin" 2>/dev/null || true
          # Set RPATH to $ORIGIN/../lib so binaries find libraries relative to their location
          patchelf --set-rpath '$ORIGIN/../lib' "$bin" 2>/dev/null || true
          # Shrink RPATH to remove any unused paths
          patchelf --shrink-rpath "$bin" 2>/dev/null || true
        fi
      done

      # Patch shared libraries to use relative RPATH
      for lib in $out/lib/*.so*; do
        if [ -f "$lib" ] && file "$lib" | grep -q ELF; then
          echo "Patching RPATH for $lib"
          # Set RPATH to $ORIGIN so libraries find other libraries in same directory
          patchelf --set-rpath '$ORIGIN' "$lib" 2>/dev/null || true
          # Shrink RPATH to remove any unused paths
          patchelf --shrink-rpath "$lib" 2>/dev/null || true
        fi
      done

      # slim-services overlay: nixpkgs proj/gdal link libsqlite3 by ABSOLUTE
      # store path (CMake full-path linking), which an ldd audit on a build
      # machine cannot catch — its /nix/store resolves the reference. Bundle
      # any such dependency next to the other libs and rewrite the NEEDED
      # entry to its basename; loop until a pass adds nothing new (bundled
      # deps can bring their own absolute references).
      changed=1
      while [ "$changed" = 1 ]; do
        changed=0
        for so in $out/lib/*.so*; do
          [ -f "$so" ] || continue
          [ -L "$so" ] && continue
          file "$so" | grep -q ELF || continue
          for needed in $(patchelf --print-needed "$so" 2>/dev/null); do
            case "$needed" in
              /nix/store/*)
                base="$(basename "$needed")"
                if [ ! -e "$out/lib/$base" ]; then
                  cp -L "$needed" "$out/lib/$base"
                  chmod u+w "$out/lib/$base"
                  strip --strip-unneeded "$out/lib/$base" 2>/dev/null || true
                  patchelf --set-rpath '$ORIGIN' "$out/lib/$base" 2>/dev/null || true
                  changed=1
                fi
                patchelf --replace-needed "$needed" "$base" "$so"
                ;;
            esac
          done
        done
      done
    ''
    + lib.optionalString stdenv.isDarwin ''
      # On macOS, patch binaries to use relative library paths
      # This makes the bundle portable across macOS systems for Supabase CLI
      for bin in $out/bin/.*-wrapped; do
        if [ -f "$bin" ] && file "$bin" | grep -q "Mach-O"; then
          # Get all dylib dependencies from the Nix store, plus any
          # libiconv/libcharset reference in @rpath form. Phases run under
          # pipefail: capture with a fallback — a binary with no matching
          # refs must not abort the build.
          bin_deps="$(otool -L "$bin" | awk 'NR > 1 {print $1}' | grep -E '^/nix/store/|^@rpath/libiconv|^@rpath/libcharset' || true)"
          echo "$bin_deps" | while read dep; do
            [ -n "$dep" ] || continue
            libname=$(basename "$dep")
            # libiconv/libcharset: two incompatible families share these
            # basenames. GNU-family refs (target exports _libiconv) go to
            # the bundled libgnuiconv.2.dylib; everything else — the Apple
            # SDK dylibs and @rpath leftovers (Apple provenance, compat 7)
            # — goes to the OS copies.
            if [ "''${libname#libcharset}" != "$libname" ]; then
              echo "Patching $bin: $dep -> /usr/lib/libcharset.1.dylib"
              install_name_tool -change "$dep" "/usr/lib/libcharset.1.dylib" "$bin" 2>/dev/null || true
              continue
            fi
            if [ "''${libname#libiconv}" != "$libname" ]; then
              if nm -gU "$dep" 2>/dev/null | grep -qw _libiconv; then
                echo "Patching $bin: $dep -> @rpath/libgnuiconv.2.dylib"
                install_name_tool -change "$dep" "@rpath/libgnuiconv.2.dylib" "$bin" 2>/dev/null || true
              else
                echo "Patching $bin: $dep -> /usr/lib/libiconv.2.dylib"
                install_name_tool -change "$dep" "/usr/lib/libiconv.2.dylib" "$bin" 2>/dev/null || true
              fi
              continue
            fi
            # Check if we have this library in our lib directory
            if [ -f "$out/lib/$libname" ]; then
              echo "Patching $bin: $dep -> @rpath/$libname"
              install_name_tool -change "$dep" "@rpath/$libname" "$bin" 2>/dev/null || true
            fi
          done
          # Add @rpath to look in @executable_path/../lib
          install_name_tool -add_rpath "@executable_path/../lib" "$bin" 2>/dev/null || true
        fi
      done

      # Patch dylibs to use @rpath for their dependencies
      for lib in $out/lib/*.dylib*; do
        if [ -f "$lib" ] && file "$lib" | grep -q "Mach-O"; then
          # First, fix the library's own ID to use @rpath
          libname=$(basename "$lib")
          install_name_tool -id "@rpath/$libname" "$lib" 2>/dev/null || true

          # Add @rpath to the library itself so it can find other libraries
          install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true

          # Then fix references to other libraries. The -id rewrite above
          # removes the store ID line, so a dylib whose remaining deps are
          # all /usr/lib (e.g. the bundled GNU libiconv, which links only
          # libSystem) makes this grep match NOTHING — capture with a
          # fallback so pipefail does not abort the phase.
          lib_deps="$(otool -L "$lib" | awk 'NR > 1 {print $1}' | grep -E '^/nix/store/|^@rpath/libiconv|^@rpath/libcharset' || true)"
          echo "$lib_deps" | while read dep; do
            [ -n "$dep" ] || continue
            deplibname=$(basename "$dep")
            # libiconv/libcharset: two incompatible families share these
            # basenames — same routing as the binary loop above.
            if [ "''${deplibname#libcharset}" != "$deplibname" ]; then
              echo "Patching $lib: $dep -> /usr/lib/libcharset.1.dylib"
              install_name_tool -change "$dep" "/usr/lib/libcharset.1.dylib" "$lib" 2>/dev/null || true
              continue
            fi
            if [ "''${deplibname#libiconv}" != "$deplibname" ]; then
              if nm -gU "$dep" 2>/dev/null | grep -qw _libiconv; then
                echo "Patching $lib: $dep -> @rpath/libgnuiconv.2.dylib"
                install_name_tool -change "$dep" "@rpath/libgnuiconv.2.dylib" "$lib" 2>/dev/null || true
              else
                echo "Patching $lib: $dep -> /usr/lib/libiconv.2.dylib"
                install_name_tool -change "$dep" "/usr/lib/libiconv.2.dylib" "$lib" 2>/dev/null || true
              fi
              continue
            fi
            if [ -f "$out/lib/$deplibname" ]; then
              echo "Patching $lib: $dep -> @rpath/$deplibname"
              install_name_tool -change "$dep" "@rpath/$deplibname" "$lib" 2>/dev/null || true
            fi
          done
        fi
      done

      # slim-services overlay: upstream rewrites install names but leaves
      # stale LC_RPATH entries pointing into /nix/store on copied libraries
      # (e.g. the ICU dylibs), which fails the portable audit. Delete Nix
      # store rpaths and re-sign — but ONLY on files actually mutated: the
      # sandbox codesign shim produces invalid signatures on some special
      # dylibs (reexport stubs like libiconv.dylib), which macOS then
      # SIGKILLs at load. scripts/audit-portable-artifact.sh verifies every
      # signature with the host codesign afterwards.
      for macho in $out/bin/.*-wrapped $out/lib/*.dylib*; do
        [ -f "$macho" ] || continue
        [ -L "$macho" ] && continue
        file "$macho" | grep -q "Mach-O" || continue
        nix_rpaths="$(otool -l "$macho" 2>/dev/null | awk '
          $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
          in_rpath && $1 == "path" { print $2; in_rpath = 0 }
        ' | grep '^/nix/store/' || true)"
        [ -n "$nix_rpaths" ] || continue
        echo "$nix_rpaths" | while read -r rpath; do
          install_name_tool -delete_rpath "$rpath" "$macho" 2>/dev/null || true
        done
        codesign --force --sign - "$macho" 2>/dev/null || true
      done
    ''
    + ''
      # slim-services overlay: the upstream tree reaches this package as a
      # symlink farm, and the `cp -rL` copies above expand every alias into a
      # full copy — postgis ships ~130 identical 8-MiB upgrade scripts, and
      # every extension exists as both name.so and name-<version>.so. Replace
      # identical siblings with relative symlinks (same directory only).
      # Runs LAST so it can never hand a symlink to the patchelf or
      # install_name_tool loops above (mutating a canonical file once per
      # alias name corrupts it). lib/ is deduped on Linux only: ELF sonames
      # are symlink-friendly by design, but Mach-O two-level namespace binds
      # symbols to each dylib's LC_ID_DYLIB, so aliasing dylibs whose IDs
      # were just rewritten per-name breaks symbol lookup (seen as
      # "Symbol not found: _libiconv" loading pg_net on darwin).
      dedup_dirs="$out/share/postgresql/extension"
      if [ "$(uname)" = "Linux" ]; then
        dedup_dirs="$dedup_dirs $out/lib"
      fi
      for dedup_dir in $dedup_dirs; do
        [ -d "$dedup_dir" ] || continue
        (
          cd "$dedup_dir"
          declare -A seen_hash
          while IFS= read -r f; do
            f="''${f#./}"
            h="$(sha256sum "$f" | cut -d' ' -f1)"
            if [ -n "''${seen_hash[$h]:-}" ]; then
              ln -sf "''${seen_hash[$h]}" "$f"
            else
              seen_hash[$h]="$f"
            fi
          done < <(find . -maxdepth 1 -type f -size +1M | LC_ALL=C sort)
        )
      done
    '';

  meta = with lib; {
    description = "Portable PostgreSQL bundle for the Supabase CLI";
    longDescription = ''
      A portable, self-contained PostgreSQL distribution designed for use
      within the Supabase CLI. Includes minimal extensions (supautils only)
      and is patched to run without Nix dependencies on target systems.
    '';
    platforms = platforms.unix;
    license = licenses.postgresql;
  };
}
