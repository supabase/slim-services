{
  pkgs,
  lib,
  stdenv,
  writeTextFile,
  patchelf,
  glibc,
  glibcLocales,
  file,
  python3,
  binutils,
  upstream,
  portablePostgres ? throw "postgres portable package requires portable-postgres helpers",
  psql_cli ? null,
  psql_17_cli ? null,
  postgres_major ? "17",
}:
assert psql_cli != null || psql_17_cli != null;
let
  configDir = "${upstream}/nix/packages/cli-config";
  dockerfile =
    if postgres_major == "orioledb-17" then
      if builtins.pathExists "${upstream}/Dockerfile-orioledb-17" then
        "${upstream}/Dockerfile-orioledb-17"
      else
        throw "Dockerfile-orioledb-17 is required for the orioledb-17 postgres line"
    else if builtins.pathExists "${upstream}/Dockerfile-supabase" then
      "${upstream}/Dockerfile-supabase"
    else
      "${upstream}/Dockerfile-${postgres_major}";
  usesIcu = lib.hasInfix "--locale-provider=icu" (builtins.readFile dockerfile);
  initdbArgs =
    if usesIcu then
      [ "--encoding=UTF-8" "--locale-provider=icu" "--icu-locale=en_US.UTF-8" "--allow-group-access" ]
    else
      [ "--encoding=UTF-8" "--locale=en_US.UTF-8" ];
  glibcLocalesMinimal = glibcLocales.override {
    allLocales = false;
    locales = [ "en_US.UTF-8/UTF-8" ];
  };

  selectedCli = if psql_cli != null then psql_cli else psql_17_cli;
  # TAP::Harness is in core perl; this package is the pgTAP source handler and
  # `pg_prove` script. A psql-driving wrapper is not a substitute — CLI test
  # parses TAP::Harness `Result:` / `Files=` lines.
  pgTAPPerl = pkgs.perlPackages.TAPParserSourceHandlerpgTAP;

  extensionNames = builtins.filter (
    name: name != "recurseForDerivations" && !(lib.hasSuffix "-pkgs" name)
  ) (builtins.attrNames selectedCli.exts);

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
  ansibleConfig = "${upstream}/ansible/files/postgresql_config";
  supautilsConf = "${upstream}/ansible/files/postgresql_config/supautils.conf.j2";
  extensionCustomScripts = "${upstream}/ansible/files/postgresql_extension_custom_scripts";
  localDevConf = ./local-dev.conf;
  stageSharedConfig = ./stage-shared-config.sh;

  receipt = writeTextFile {
    name = "cli-receipt";
    destination = "/receipt.json";
    text = builtins.toJSON {
      variant = "cli";
      psql-version = selectedCli.bin.version;
      # Keep receipt-version=1's consumed list-of-strings schema; names are
      # derived from the selected major's package rather than hardcoded.
      extensions = extensionNames;
      receipt-version = "1";
    };
  };

  migrationBundle = stdenv.mkDerivation {
    name = "cli-migration-bundle";
    src = "${upstream}/migrations/db";
    dontPatchShebangs = true;
    nativeBuildInputs = [ pkgs.patch ];
    installPhase = ''
      mkdir -p $out/share/supabase-cli/migrations
      cp -r init-scripts $out/share/supabase-cli/migrations/
      cp -r migrations $out/share/supabase-cli/migrations/
      cp migrate.sh $out/share/supabase-cli/migrations/
      ${pkgs.patch}/bin/patch $out/share/supabase-cli/migrations/migrate.sh \
        < ${./migrate-batch.patch}
      chmod +x $out/share/supabase-cli/migrations/migrate.sh

      # Add pgbouncer schema (same as Docker build does)
      cp ${upstream}/ansible/files/pgbouncer_config/pgbouncer_auth_schema.sql \
         $out/share/supabase-cli/migrations/init-scripts/00-schema.sql

      # Add pg_stat_statements extension (same as Docker build does)
      cp ${upstream}/ansible/files/stat_extension.sql \
         $out/share/supabase-cli/migrations/migrations/00-extension.sql
      if [ "${postgres_major}" = "orioledb-17" ]; then
        printf '%s\n' "CREATE EXTENSION orioledb;" \
          > $out/share/supabase-cli/migrations/init-scripts/00-pre-init.sql
      fi
    '';
  };

  configBundle = stdenv.mkDerivation {
    name = "cli-config-bundle";
    src = configDir;
    dontPatchShebangs = true;
    nativeBuildInputs = [ pkgs.patch ];
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
        -e "s/db_user_namespace = off/#db_user_namespace = off/g" \
        $conf
      # Dockerfile-17 and Dockerfile-orioledb-17 remove extensions incompatible
      # with that engine. PG15 retains the source tree's TimescaleDB/plv8 preload values.
      if [ "${postgres_major}" = "17" ] || [ "${postgres_major}" = "orioledb-17" ]; then
        sed -i -e "s/ timescaledb,//g" -e "s/ plv8,//g" $conf
      fi
      if [ "${postgres_major}" = "orioledb-17" ]; then
        sed -i -E "s/(shared_preload_libraries = '[^']*)'/\\1, orioledb'/" $conf
        printf '\n%s\n' "default_table_access_method = 'orioledb'" >> $conf
      fi
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
      if [ "${postgres_major}" = "15" ]; then
        grep "^shared_preload_libraries" $conf | grep -q timescaledb || {
          echo "PG15 source config lost TimescaleDB preload" >&2
          exit 1
        }
      elif grep "^shared_preload_libraries" $conf | grep -q "timescaledb\|plv8"; then
        echo "PG17-incompatible extension left in shared_preload_libraries" >&2
        exit 1
      fi
      if [ "${postgres_major}" = "orioledb-17" ]; then
        grep "^shared_preload_libraries" $conf | grep -q "orioledb" || {
          echo "OrioleDB shared_preload_libraries is missing orioledb" >&2
          exit 1
        }
        grep -q "^default_table_access_method = 'orioledb'" $conf || {
          echo "OrioleDB default_table_access_method is missing" >&2
          exit 1
        }
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
      # Dockerfile-17 strips TimescaleDB/plv8 from supautils.conf; PG15 keeps
      # the exact source-tree values.
      if [ "${postgres_major}" = "orioledb-17" ]; then
        sed 's/ timescaledb,//g; s/ plv8,//g; s/ postgis,//g; s/ pgrouting,//g' ${supautilsConf} > $cfg/supautils.conf
      elif [ "${postgres_major}" = "17" ]; then
        sed 's/ timescaledb,//g; s/ plv8,//g' ${supautilsConf} > $cfg/supautils.conf
      else
        cp ${supautilsConf} $cfg/supautils.conf
      fi
      grep -q "^supautils.privileged_extensions = " $cfg/supautils.conf || {
        echo "supautils.conf lost its allowlist" >&2
        exit 1
      }
      if [ "${postgres_major}" = "orioledb-17" ]; then
        if grep "^supautils.privileged_extensions" $cfg/supautils.conf | grep -Eq '(^|, )(timescaledb|plv8|postgis|pgrouting),'; then
          echo "OrioleDB supautils allowlist still contains a stripped extension" >&2
          exit 1
        fi
      fi

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

      # Patch the init script (the pwfile replacement is anchored to the
      # pinned upstream script; locale arguments follow the selected
      # Dockerfile's feature-detected initdb contract):
      #  1. source stage-shared-config.sh after the config templates are
      #     copied into PGDATA;
      #  2. initdb with the selected upstream Dockerfile's locale contract and
      #     a temporary password file. The source shape is asserted below.
      init=$out/share/supabase-cli/bin/supabase-postgres-init.sh
      ${pkgs.patch}/bin/patch "$init" < ${./postgres-init-pwfile.patch}
      substituteInPlace "$init" \
        --replace-fail '@INITDB_ARGS@' ${lib.escapeShellArg (lib.escapeShellArgs initdbArgs)}
      sed -i \
        -e '/pg_ident.conf.template/a\	. "$BUNDLE_DIR/share/supabase-cli/bin/stage-shared-config.sh"' \
        $init
      for want in "stage-shared-config.sh" "--pwfile="; do
        grep -q -- "$want" $init || {
          echo "init-script patch anchor missing: $want" >&2
          exit 1
        }
      done
      if grep -q "postgres_setup_password\|--single.*ALTER USER" $init; then
        echo "init script still boots PostgreSQL for the bootstrap password" >&2
        exit 1
      fi
      bash -n $init
    '';
  };
in
stdenv.mkDerivation {
  name = "psql_${postgres_major}_cli_portable";
  version = selectedCli.bin.version;

  dontUnpack = true;
  dontPatchShebangs = true;
  # The Linux fixup below owns stripping and ELF patching so pinned glibc
  # objects remain byte-preserved. Keep generic stdenv fixups away from them.
  dontStrip = stdenv.isLinux;
  dontPatchELF = stdenv.isLinux;
  nativeBuildInputs = lib.optionals stdenv.isLinux [
    patchelf
    file
    python3
    binutils
  ];

  buildPhase = ''
    mkdir -p $out/bin $out/lib $out/share

    # List of PostgreSQL binaries to include in the Supabase CLI bundle.
    # `perl` is the relocatable interpreter for bundled `pg_prove`.
    binaries="postgres pg_config pg_ctl initdb psql pg_dump pg_dumpall pg_restore createdb dropdb pg_isready perl"

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

    # Helper function to list library files based on platform. Darwin
    # extensions are Mach-O .so files as well as .dylib files.
    find_library_files() {
      if [ "$(uname)" = "Darwin" ]; then
        find "$out/lib" -type f \( -name "*.dylib*" -o -name "*.so*" \)
      else
        find "$out/lib" -type f -name "*.so*"
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
      src=""
      if [ "$bin" = "perl" ]; then
        src="${pkgs.perl}/bin/perl"
      elif [ -f ${selectedCli.bin}/bin/$bin ] || [ -L ${selectedCli.bin}/bin/$bin ]; then
        src="${selectedCli.bin}/bin/$bin"
      fi
      if [ -n "$src" ] && { [ -f "$src" ] || [ -L "$src" ]; }; then
        actual_binary=$(resolve_binary "$src")
        if [ -n "$actual_binary" ] && [ -f "$actual_binary" ]; then
          cp "$actual_binary" $out/bin/.$bin-wrapped 2>/dev/null || true
        fi
      fi
    done

    # Copy all shared libraries from PostgreSQL
    if [ -d ${selectedCli.bin}/lib ]; then
      cp -rL ${selectedCli.bin}/lib/* $out/lib/ 2>/dev/null || true
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
    for iteration in {1..5}; do
      before_count=$(find_library_files 2>/dev/null | wc -l || echo "0")
      # Use find instead of globs to avoid bash errors when a pattern does not match.
      libs=$(find_library_files 2>/dev/null || true)
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
      after_count=$(find_library_files 2>/dev/null | wc -l || echo "0")
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
    if [ -d ${selectedCli.bin}/share ]; then
      cp -rL ${selectedCli.bin}/share/* $out/share/ 2>/dev/null || true
    fi

    # Relocatable perl lib + TAP::Parser::SourceHandler::pgTAP. Omit man/pod;
    # PERL5LIB in bin/pg_prove replaces compiled-in @INC.
    mkdir -p $out/lib/perl5 $out/libexec
    if [ -d ${pkgs.perl}/lib/perl5 ]; then
      cp -rL ${pkgs.perl}/lib/perl5/. $out/lib/perl5/
    fi
    # Nix copies keep 555 dirs; TAP merge and man/pod strip need a writable tree.
    chmod -R u+w $out/lib/perl5
    if [ -d ${pgTAPPerl}/lib/perl5 ]; then
      cp -rL ${pgTAPPerl}/lib/perl5/. $out/lib/perl5/
      chmod -R u+w $out/lib/perl5
    fi
    find $out/lib/perl5 -type d -name man 2>/dev/null | while IFS= read -r man_dir; do
      rm -rf "$man_dir"
    done
    find $out/lib/perl5 -name '*.pod' -delete 2>/dev/null || true
    if [ -f ${pgTAPPerl}/bin/pg_prove ]; then
      cp ${pgTAPPerl}/bin/pg_prove $out/libexec/pg_prove
      chmod 0644 $out/libexec/pg_prove
    fi

    perl5_inc=""
    add_perl5_inc() {
      [ -d "$1" ] || return 0
      case ":$perl5_inc:" in
        *":$1:"*) return 0 ;;
      esac
      rel="''${1#$out/}"
      perl5_inc="''${perl5_inc:+$perl5_inc:}@ROOT@/$rel"
    }
    for perl5_verdir in $out/lib/perl5/site_perl/5.*; do
      [ -d "$perl5_verdir" ] || continue
      for perl5_arch in "$perl5_verdir"/*-thread-* "$perl5_verdir"/*-linux-* "$perl5_verdir"/*-darwin-*; do
        add_perl5_inc "$perl5_arch"
      done
      add_perl5_inc "$perl5_verdir"
    done
    add_perl5_inc $out/lib/perl5/site_perl
    for perl5_verdir in $out/lib/perl5/5.*; do
      [ -d "$perl5_verdir" ] || continue
      for perl5_arch in "$perl5_verdir"/*-thread-* "$perl5_verdir"/*-linux-* "$perl5_verdir"/*-darwin-*; do
        add_perl5_inc "$perl5_arch"
      done
      add_perl5_inc "$perl5_verdir"
    done
    add_perl5_inc $out/lib/perl5
    [ -n "$perl5_inc" ] || {
      echo "bundled perl5 library path is empty" >&2
      exit 1
    }

    cat > $out/bin/pg_prove << 'WRAPPER_EOF'
#!/bin/sh
case "$0" in
  */*) SCRIPT_DIR="''${0%/*}"; [ -n "$SCRIPT_DIR" ] || SCRIPT_DIR=/ ;;
  *) SCRIPT_DIR=. ;;
esac
SCRIPT_DIR="$(CDPATH= cd "$SCRIPT_DIR" && pwd -P)"
ROOT="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
export PATH="$SCRIPT_DIR''${PATH:+:$PATH}"
export PERL5LIB="@PERL5LIB@''${PERL5LIB:+:$PERL5LIB}"
exec "$SCRIPT_DIR/perl" "$ROOT/libexec/pg_prove" "$@"
WRAPPER_EOF
    substituteInPlace $out/bin/pg_prove --replace-fail '@PERL5LIB@' "$perl5_inc"
    # PERL5LIB paths are recorded as @ROOT@/<rel> so the wrapper expands $ROOT
    # at runtime instead of baking the Nix store prefix.
    sed -i 's|@ROOT@|$ROOT|g' $out/bin/pg_prove
    chmod 0755 $out/bin/pg_prove
    [ -x $out/bin/.perl-wrapped ] || {
      echo "bundled perl interpreter is missing" >&2
      exit 1
    }
    [ -f $out/libexec/pg_prove ] || {
      echo "bundled pg_prove script is missing" >&2
      exit 1
    }

    # Add the CLI config bundle wholesale (config/ including conf.d, bin/,
    # extension-custom-scripts/) — a flat `cp dir/*` omits the directories
    # the shared recipe added.
    mkdir -p $out/share/supabase-cli
    cp -R ${configBundle}/share/supabase-cli/. $out/share/supabase-cli/

    # Add migration files
    cp -r ${migrationBundle}/share/supabase-cli/migrations $out/share/supabase-cli/

    # Service-owned lifecycle command. It is deliberately a small shell
    # adapter around the versioned init script and migration bundle so native
    # artifacts and derived images share exactly one first-boot contract.
    install -m 0755 ${./postgres-start.sh} $out/bin/supabase-postgres-start

    # Add receipt
    cp ${receipt}/receipt.json $out/cli-receipt.json
  '';

  installPhase = ''
        # Darwin keeps the upstream shell wrappers and DYLD behavior. Linux
        # public entrypoints are generated by the portable fixup after the
        # exact bundled loader/library path is known.
        if [ "$(uname)" = "Darwin" ]; then
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
        fi
  '';

  postFixup =
    lib.optionalString stdenv.isLinux ''
      PORTABLE_POSTGRES_ROOTFS="$out" \
        PORTABLE_POSTGRES_GLIBC_LIB="${glibc}/lib" \
        PORTABLE_POSTGRES_GLIBC_ROOT="${glibc}" \
        PORTABLE_POSTGRES_GLIBC_SRC="${glibc.src}" \
        PORTABLE_POSTGRES_LOCALE_LIB="${glibcLocalesMinimal}/lib/locale" \
        PORTABLE_POSTGRES_COMPILER_LIB="${lib.getLib stdenv.cc.cc}" \
        PORTABLE_POSTGRES_COMPILER_LIBGCC="${
          if stdenv.cc.cc ? libgcc then stdenv.cc.cc.libgcc else lib.getLib stdenv.cc.cc
        }" \
        PORTABLE_POSTGRES_COMPILER_SRC="${stdenv.cc.cc.src}" \
        PORTABLE_POSTGRES_GLIBC_VERSION="${glibc.version}" \
        PORTABLE_POSTGRES_COMPILER_VERSION="${stdenv.cc.cc.version}" \
        PORTABLE_POSTGRES_LAUNCHER="${portablePostgres}/postgres-launcher.sh" \
        PORTABLE_POSTGRES_ENTRYPOINT_HELPER="${portablePostgres}/postgres-entrypoint-fixup.sh" \
        PORTABLE_POSTGRES_COMPILER_HELPER="${portablePostgres}/postgres-compiler-runtime.sh" \
        . ${portablePostgres}/postgres-linux-fixup.sh
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

      # Patch Mach-O libraries to use @rpath for their dependencies. Darwin
      # extension modules use the .so suffix, while system libraries use
      # .dylib, so process both. Perl XS lives under lib/perl5.
      perl5_macho=""
      if [ -d "$out/lib/perl5" ]; then
        perl5_macho="$(find "$out/lib/perl5" -type f \( -name '*.bundle' -o -name '*.dylib*' -o -name '*.so*' \) 2>/dev/null || true)"
      fi
      for lib in $out/lib/*.dylib* $out/lib/*.so* $perl5_macho; do
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
      # Mach-O libraries (reexport stubs like libiconv.dylib), which macOS then
      # SIGKILLs at load. scripts/audit-portable-artifact.sh verifies every
      # signature with the host codesign afterwards.
      for macho in $out/bin/.*-wrapped $out/lib/*.dylib* $out/lib/*.so* $perl5_macho; do
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
      # Preload loads $libdir/name; CREATE EXTENSION uses module_pathname.
      # After cp -rL the versioned and unversioned .so are two files, and
      # Darwin cannot collapse lib/ to one inode (Mach-O LC_ID_DYLIB). Point
      # CREATE at the same path string preload already loaded.
      ext_dir="$out/share/postgresql/extension"
      lib_dir="$out/lib"
      if [ -d "$ext_dir" ] && [ -d "$lib_dir" ]; then
        for control in "$ext_dir"/*.control; do
          [ -f "$control" ] || continue
          pathname="$(awk -F"'" '/^module_pathname/ { print $2; exit }' "$control")"
          case "$pathname" in
            '$libdir/'*) module="''${pathname#'$libdir/'}" ;;
            *) continue ;;
          esac
          unversioned="$(printf '%s\n' "$module" | sed -E 's/-[0-9][0-9.]*$//')"
          [ "$unversioned" != "$module" ] || continue
          so=""
          for suffix in so dylib; do
            if [ -e "$lib_dir/$unversioned.$suffix" ] && [ -e "$lib_dir/$module.$suffix" ]; then
              so="$suffix"
              break
            fi
          done
          [ -n "$so" ] || continue
          sed -i "s|^module_pathname[[:space:]]*=[[:space:]].*|module_pathname = '\$libdir/$unversioned'|" "$control"
        done
      fi

      # slim-services overlay: the upstream tree reaches this package as a
      # symlink farm, and the `cp -rL` copies above expand every alias into a
      # full copy — postgis ships ~130 identical 8-MiB upgrade scripts, and
      # every extension exists as both name.so and name-<version>.so. Replace
      # identical siblings with relative symlinks (same directory only).
      # The name.so/name-<version>.so pair MUST collapse to one inode, not
      # just for disk: shared_preload_libraries loads the unversioned name
      # while the extension's module_pathname loads the versioned one, and
      # postgres keys loaded libraries by path string — with one inode,
      # dlopen returns the same handle and the second _PG_init self-guards
      # (the docker.io layout); with two real files the library initializes
      # twice and dies with "attempt to redefine parameter" the moment an
      # extension is both preloaded and created (seen live with
      # plpgsql_check under the shared-recipe preload set). So dedup every
      # identical file, not only the >1M ones.
      # Runs LAST so it can never hand a symlink to the patchelf or
      # install_name_tool loops above (mutating a canonical file once per
      # alias name corrupts it). lib/ is deduped on Linux only: ELF sonames
      # are symlink-friendly by design, but Mach-O two-level namespace binds
      # symbols to each dylib's LC_ID_DYLIB, so aliasing dylibs whose IDs
      # were just rewritten per-name breaks symbol lookup (seen as
      # "Symbol not found: _libiconv" loading pg_net on darwin). CREATE
      # EXTENSION still works on Darwin because the control-file rewrite
      # above makes module_pathname match the preload path.
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
          done < <(find . -maxdepth 1 -type f | LC_ALL=C sort)
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
