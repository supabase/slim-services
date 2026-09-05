{
  pkgs,
  service,
  rootfs,
  tag,
  identity ? { },
  labels ? { },
}:

/*
  Build the OCI image from the already audited portable artifact.

  The artifact is deliberately accepted as an input rather than rebuilding a
  service here.  This keeps the host runtime and image runtime identical while
  allowing image construction to remain a normal, pinned Nix derivation.
*/
let
  lib = pkgs.lib;
  # Tini 0.19 uses basename without its POSIX declaration. The musl static
  # build needs this header; keep the upstream warning checks enabled.
  tini = pkgs.pkgsStatic.tini.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/tini.c \
        --replace-fail '#include <stdlib.h>' '#include <stdlib.h>
      #include <libgen.h>'
    '';
  });
  root = builtins.path {
    path = rootfs;
    name = "${service}-portable-rootfs";
  };

  serviceDefinitions = {
    analytics = {
      root = "/opt/app/rel/logflare";
      workdir = "/opt/app/rel/logflare/bin";
      overlay = ../../services/analytics/overlay/entry.sh;
      overlayPath = "/opt/app/rel/logflare/entry.sh";
      entrypoint = [
        "/usr/bin/tini"
        "-s"
        "-g"
        "--"
        "/usr/bin/sh"
        "/opt/app/rel/logflare/entry.sh"
      ];
      cmd = null;
      ports = [ 4000 ];
      tools = [
        "beam"
        "ca"
      ];
      rootfsMode = "beam";
      user = "65532:65532";
    };

    auth = {
      overlay = null;
      entrypoint = [ ];
      cmd = [ "gotrue" ];
      ports = [ 9999 ];
      tools = [ "ca" ];
      rootfsMode = "auth";
      extraEnv = [ "PORT=9999" ];
      user = "1000:1000";
      healthcheck = [
        "CMD-SHELL"
        "wget --spider http://127.0.0.1:9999/health"
      ];
      healthTimeout = 5;
    };

    edge-runtime = {
      overlay = null;
      entrypoint = [ "/bin/.edge-runtime-wrapped" ];
      cmd = null;
      ports = [ ];
      tools = [ "ca" ];
      rootfsMode = "edge";
      extraEnv = [
        "LD_LIBRARY_PATH=/lib"
        "ORT_DYLIB_PATH=/lib/libonnxruntime.so"
      ];
    };

    pgmeta = {
      overlay = null;
      entrypoint = [ ];
      cmd = [
        "node"
        "dist/server/server.js"
      ];
      ports = [ 8080 ];
      tools = [ "ca" ];
      rootfsMode = "node";
      root = "/usr/src/app";
      workdir = "/usr/src/app";
      user = "65532:65532";
      extraEnv = [
        "PG_META_PORT=8080"
        "PATH=/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      ];
      healthcheck = [
        "CMD-SHELL"
        "node --eval=\"fetch('http://127.0.0.1:8080/health').then((r) => {if (!r.ok) throw new Error(r.status)})\""
      ];
      healthTimeout = 5;
    };

    pooler = {
      root = "/app";
      workdir = "/app";
      overlay = ../../services/pooler/overlay/entry.sh;
      overlayPath = "/app/entry.sh";
      entrypoint = [
        "/usr/bin/tini"
        "-s"
        "-g"
        "--"
        "/usr/bin/sh"
        "/app/entry.sh"
      ];
      cmd = [ "/app/bin/server" ];
      ports = [ 4000 ];
      tools = [
        "beam"
        "ca"
      ];
      rootfsMode = "beam";
      extraEnv = [ "NODE_IP=127.0.0.1" ];
      user = "65532:65532";
    };

    postgres = {
      root = "/opt/postgres";
      overlay = ../../services/postgres/overlay/entry.sh;
      overlayPath = "/usr/local/bin/entry.sh";
      secondOverlay = ../../services/postgres/overlay/docker-entrypoint.sh;
      secondOverlayPath = "/usr/local/bin/docker-entrypoint.sh";
      entrypoint = [ "/usr/local/bin/docker-entrypoint.sh" ];
      cmd = [
        "postgres"
        "-D"
        "/etc/postgresql"
      ];
      ports = [ 5432 ];
      tools = [
        "postgres"
        "ca"
      ];
      rootfsMode = "postgres";
      extraEnv = [
        "PGDATA=/var/lib/postgresql/data"
        "POSTGRES_USER=supabase_admin"
        "POSTGRES_DB=postgres"
        "LANG=en_US.UTF-8"
        "LANGUAGE=en_US:en"
        "LC_ALL=en_US.UTF-8"
        "PATH=/opt/postgres/bin:/usr/local/bin:/usr/bin:/bin"
      ];
    };

    postgrest = {
      overlay = null;
      entrypoint = [ ];
      cmd = [ "/bin/postgrest" ];
      ports = [ 3000 ];
      tools = [ ];
      rootfsMode = "full";
      user = "1000:1000";
    };

    realtime = {
      root = "/app";
      workdir = "/app";
      overlay = ../../services/realtime/overlay/entry.sh;
      overlayPath = "/app/entry.sh";
      entrypoint = [
        "/usr/bin/tini"
        "-s"
        "-g"
        "--"
        "/usr/bin/sh"
        "/app/entry.sh"
      ];
      cmd = [ "/app/bin/server" ];
      ports = [ 4000 ];
      tools = [
        "beam"
        "ca"
      ];
      rootfsMode = "beam";
      extraEnv = [ ];
      user = "65532:65532";
    };

    storage = {
      overlay = null;
      entrypoint = [ ];
      cmd = [
        "/node/bin/node"
        "dist/start/server.js"
      ];
      ports = [ 5000 ];
      tools = [ "ca" ];
      rootfsMode = "node";
      root = "/app";
      workdir = "/app";
      extraEnv = [
        "NODE_ENV=production"
        "PATH=/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      ];
      healthcheck = [
        "CMD"
        "/node/bin/node"
        "-e"
        "fetch('http://127.0.0.1:'+(process.env.SERVER_PORT||process.env.PORT||5000)+'/status').then((r)=>process.exit(r.ok?0:1),()=>process.exit(1))"
      ];
      healthTimeout = 5;
    };

    studio = {
      overlay = null;
      entrypoint = [
        "/node/bin/node"
        "/app/apps/studio/docker-entrypoint.mjs"
      ];
      cmd = [
        "/node/bin/node"
        "apps/studio/server.js"
      ];
      ports = [ 3000 ];
      tools = [ "ca" ];
      rootfsMode = "node";
      root = "/app";
      workdir = "/app";
      user = "65532:65532";
      extraEnv = [
        "NODE_ENV=production"
        "PORT=3000"
        "HOSTNAME=0.0.0.0"
        "PATH=/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      ];
      healthcheck = [
        "CMD-SHELL"
        "node --eval=\"fetch('http://127.0.0.1:3000/api/platform/profile').then((r) => {if (!r.ok) throw new Error(r.status)})\""
      ];
      healthTimeout = 10;
    };
  };

  cfg = {
    root = "/";
    overlay = null;
    overlayPath = "/";
    secondOverlay = null;
    secondOverlayPath = "/";
  }
  // (serviceDefinitions.${service} or (throw "no Nix image definition for ${service}"));
  imageNameParts = lib.splitString ":" tag;
  imageName = lib.concatStringsSep ":" (lib.take (lib.length imageNameParts - 1) imageNameParts);
  imageTag = lib.last imageNameParts;

  runtimeEnvFile = ../../services/${service}/runtime.env;
  runtimeLines =
    if builtins.pathExists runtimeEnvFile then
      lib.filter (line: line != "" && !(lib.hasPrefix "#" line)) (
        lib.splitString "\n" (builtins.readFile runtimeEnvFile)
      )
    else
      [ ];
  runtimeEnv = map (
    line:
    let
      parts = lib.splitString "=" line;
    in
    "${lib.head parts}=${lib.concatStringsSep "=" (lib.tail parts)}"
  ) runtimeLines;

  identityEnv = lib.optionalAttrs (identity ? uid) {
    DROP_TO_UID = toString identity.uid;
    DROP_TO_GID = toString identity.gid;
    DROP_TO_NAME = identity.name;
    VOLUME_MODE = identity.mode;
  };
  # Identity probing controls volume ownership. Container start users remain
  # service-defined: postgres, storage, and edge-runtime intentionally start
  # as root so their entrypoints can prepare Docker-created volumes.
  identityUser = if cfg ? user then cfg.user else "";

  imageRoot =
    pkgs.runCommand "${service}-image-root"
      {
        nativeBuildInputs = [ pkgs.coreutils ];
        passthru.rootfs = root;
      }
      ''
        set -euo pipefail
        mkdir -p "$out"
        mkdir -p "$out/tmp"

        copy_tree() {
          source="$1"
          destination="$2"
          [ -e "${root}/$source" ] || {
            echo "missing required artifact path: $source" >&2
            exit 1
          }
          mkdir -p "$out/$(dirname "$destination")"
          cp -a "${root}/$source" "$out/$destination"
        }

        case "${cfg.rootfsMode}" in
          auth)
            copy_tree bin/auth usr/local/bin/auth
            mkdir -p "$out/usr/local/bin"
            ln -s auth "$out/usr/local/bin/gotrue"
            ;;
          edge)
            copy_tree bin usr/bin
            copy_tree lib lib
            chmod -R u+w "$out/lib"
            # The edge artifact deliberately leaves the host glibc out so native
            # execution can use the host ABI. A scratch image has no host loader,
            # so copy the matching pinned glibc family into its expected paths.
            mkdir -p "$out/lib" "$out/lib64"
            for pattern in \
              "ld-linux*.so.*" "libc.so*" "libc-*.so.*" "libm.so*" "libm-*.so.*" \
              "libmvec.so*" "libmvec-*.so.*" "libdl.so*" "libdl-*.so.*" \
              "libpthread.so*" "libpthread-*.so.*" "libresolv.so*" "libresolv-*.so.*" \
              "librt.so*" "librt-*.so.*" "libutil.so*" "libutil-*.so.*" \
              "libanl.so*" "libanl-*.so.*" "libBrokenLocale.so*" "libBrokenLocale-*.so.*" \
              "libthread_db.so*" "libthread_db-*.so.*" "libnss_*.so*" "libnsl.so*" "libnsl-*.so.*"; do
              for glibc_file in ${pkgs.glibc}/lib/$pattern; do
                [ -e "$glibc_file" ] || continue
                cp -aL "$glibc_file" "$out/lib/$(basename "$glibc_file")"
              done
            done
            if [ -e "$out/lib/ld-linux-x86-64.so.2" ]; then
              ln -sf ../lib/ld-linux-x86-64.so.2 "$out/lib64/ld-linux-x86-64.so.2"
            fi
            mkdir -p "$out/bin"
            ln -sf ../usr/bin/edge-runtime "$out/bin/edge-runtime"
            ln -sf ../usr/bin/.edge-runtime-wrapped "$out/bin/.edge-runtime-wrapped"
            mkdir -p "$out/root"
            ;;
          node)
            copy_tree app "${cfg.root or "/app"}"
            copy_tree node slim-runtime/node
            copy_tree lib slim-runtime/lib
            ln -sf /slim-runtime/node "$out/node"
            ;;
          postgres)
            copy_tree . opt/postgres
            mkdir -p "$out/etc/postgresql" "$out/etc/postgresql-custom" \
              "$out/docker-entrypoint-initdb.d" "$out/run/postgresql" \
              "$out/var/lib/postgresql/data" "$out/usr/lib/locale"
            # The portable bundle owns the matching glibc locale archive. Reuse it
            # for the static image shell instead of adding a second locale closure.
            ln -s /opt/postgres/lib/locale/locale-archive "$out/usr/lib/locale/locale-archive"
            {
              printf '%s\n' "data_directory = '/var/lib/postgresql/data'"
              printf '%s\n' "hba_file = '/var/lib/postgresql/data/pg_hba.conf'"
              printf '%s\n' "ident_file = '/var/lib/postgresql/data/pg_ident.conf'"
              printf '%s\n' "include '/opt/postgres/share/supabase-cli/config/postgresql.conf.template'"
              printf '%s\n' "listen_addresses = '*'" "port = 5432"
              printf '%s\n' "unix_socket_directories = '/run/postgresql,/tmp'"
              printf '%s\n' "pgsodium.getkey_script = '/opt/postgres/share/supabase-cli/config/pgsodium_getkey.sh'"
              printf '%s\n' "vault.getkey_script = '/opt/postgres/share/supabase-cli/config/pgsodium_getkey.sh'"
            } > "$out/etc/postgresql/postgresql.conf"
            ;;
          beam)
            copy_tree . "${cfg.root}"
            ;;
          full)
            copy_tree . .
            ;;
          *)
            echo "unknown rootfs mode: ${cfg.rootfsMode}" >&2
            exit 1
            ;;
        esac

        chmod -R u+w "$out"

        add_busybox() {
          mkdir -p "$out/bin" "$out/usr/bin"
          if [ ! -e "$out/bin/busybox" ]; then
            cp -L ${pkgs.pkgsStatic.busybox}/bin/busybox "$out/bin/busybox"
            ln -s ../../bin/busybox "$out/usr/bin/busybox"
          fi
          for applet in ${
            lib.concatStringsSep " " (
              if service == "postgres" then
                [
                  "sh"
                  "basename"
                  "cat"
                  "chmod"
                  "chown"
                  "cp"
                  "cut"
                  "date"
                  "dirname"
                  "env"
                  "grep"
                  "gunzip"
                  "head"
                  "id"
                  "mkdir"
                  "od"
                  "readlink"
                  "rm"
                  "sed"
                  "sleep"
                  "stat"
                  "su"
                  "tr"
                  "uname"
                  "uniq"
                  "wc"
                  "wget"
                ]
              else if service == "edge-runtime" then
                [
                  "sh"
                  "cat"
                  "dirname"
                  "uname"
                  "chmod"
                  "stat"
                ]
              else if service == "auth" || service == "postgrest" then
                [
                  "sh"
                  "wget"
                ]
              else if service == "storage" then
                [
                  "sh"
                  "wget"
                  "mkdir"
                  "chown"
                  "chmod"
                  "stat"
                ]
              else
                [
                  "sh"
                  "wget"
                  "awk"
                  "basename"
                  "cat"
                  "cut"
                  "date"
                  "dirname"
                  "env"
                  "grep"
                  "head"
                  "hostname"
                  "mkdir"
                  "readlink"
                  "rm"
                  "sed"
                  "sleep"
                  "tr"
                  "uname"
                  "wc"
                  "df"
                ]
            )
          }; do
            ln -sf ../bin/busybox "$out/usr/bin/$applet"
            ln -sf busybox "$out/bin/$applet"
          done
        }

        add_busybox
        ${lib.optionalString (lib.elem "beam" cfg.tools) ''
          mkdir -p "$out/usr/bin"
          cp -L ${tini}/bin/tini "$out/usr/bin/tini"
          rm "$out/usr/bin/df"
          printf '#!/bin/sh\nexec /usr/bin/busybox df -k "$@"\n' > "$out/usr/bin/df"
          chmod 0755 "$out/usr/bin/df"
          ln -sf ../usr/bin/df "$out/bin/df"
        ''}
        ${lib.optionalString (service == "postgres") ''
          # postgres' init script intentionally invokes bash; keep that seam while
          # avoiding a dynamic /nix/store interpreter in the scratch image.
          cp -L ${pkgs.pkgsStatic.bash}/bin/bash "$out/usr/bin/bash"
          ln -s ../usr/bin/bash "$out/bin/bash"
        ''}
        ${lib.optionalString (lib.elem "ca" cfg.tools) ''
          mkdir -p "$out/etc/ssl/certs"
          cp -L ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$out/etc/ssl/certs/ca-certificates.crt"
        ''}
        ${lib.optionalString (cfg.rootfsMode == "auth") ''
          mkdir -p "$out/etc"
          printf '%s\n' 'root:x:0:0:root:/root:/sbin/nologin' 'supabase:x:1000:1000:supabase:/nonexistent:/sbin/nologin' > "$out/etc/passwd"
          printf '%s\n' 'root:x:0:' 'supabase:x:1000:' > "$out/etc/group"
        ''}
        ${lib.optionalString (service == "postgrest") ''
          mkdir -p "$out/etc"
          printf '%s\n' 'root:x:0:0:root:/root:/sbin/nologin' 'supabase:x:1000:1000:supabase:/nonexistent:/sbin/nologin' > "$out/etc/passwd"
          printf '%s\n' 'root:x:0:' 'supabase:x:1000:' > "$out/etc/group"
        ''}
        ${lib.optionalString (cfg.rootfsMode == "postgres") ''
          mkdir -p "$out/etc"
          printf '%s\n' 'root:x:0:0:root:/root:/sbin/nologin' > "$out/etc/passwd"
          printf '%s\n' 'root:x:0:' > "$out/etc/group"
          if [ -n "${toString (identity.uid or 0)}" ] && [ "${toString (identity.uid or 0)}" != 0 ]; then
            printf '%s:x:%s:%s::/var/lib/postgresql:/usr/bin/sh\n' \
              '${identity.name or "postgres"}' '${toString (identity.uid or 0)}' '${toString (identity.gid or 0)}' >> "$out/etc/passwd"
            printf '%s:x:%s:\n' '${identity.name or "postgres"}' '${toString (identity.gid or 0)}' >> "$out/etc/group"
          fi
          mkdir -p "$out/etc/postgresql" "$out/etc/postgresql-custom" "$out/docker-entrypoint-initdb.d" "$out/run/postgresql" "$out/var/lib/postgresql/data"
        ''}
        ${lib.optionalString ((cfg.user or "") == "65532:65532") ''
          mkdir -p "$out/etc"
          mkdir -p "$out/home/nonroot"
          printf '%s\n' 'root:x:0:0:root:/root:/sbin/nologin' 'nonroot:x:65532:65532:nonroot:/home/nonroot:/usr/bin/sh' > "$out/etc/passwd"
          printf '%s\n' 'root:x:0:' 'nonroot:x:65532:' > "$out/etc/group"
        ''}
        ${lib.optionalString (cfg ? overlay && cfg.overlay != null) ''
          mkdir -p "$out/$(dirname '${cfg.overlayPath}')"
          cp ${cfg.overlay} "$out${cfg.overlayPath}"
          chmod 0755 "$out${cfg.overlayPath}"
        ''}
        ${lib.optionalString (cfg.secondOverlay != null) ''
          mkdir -p "$out/$(dirname '${cfg.secondOverlayPath}')"
          cp ${cfg.secondOverlay} "$out${cfg.secondOverlayPath}"
          chmod 0755 "$out${cfg.secondOverlayPath}"
        ''}
        ${lib.optionalString (service == "storage") ''
          mkdir -p "$out/mnt"
        ''}
      '';

  defaultPath = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
  envWithoutPath = runtimeEnv ++ (cfg.extraEnv or [ ]);
  env =
    lib.optional (!(lib.any (line: lib.hasPrefix "PATH=" line) envWithoutPath)) defaultPath
    ++ envWithoutPath
    ++ lib.optional ((cfg.user or "") == "65532:65532") "HOME=/home/nonroot"
    ++ lib.mapAttrsToList (name: value: "${name}=${value}") identityEnv;
  config = {
    Entrypoint = cfg.entrypoint;
    Cmd = cfg.cmd;
    Env = env;
    WorkingDir = cfg.workdir or "";
    ExposedPorts = lib.listToAttrs (
      map (port: {
        name = "${toString port}/tcp";
        value = { };
      }) (cfg.ports or [ ])
    );
    User = identityUser;
    Healthcheck = lib.optionalAttrs (cfg ? healthcheck) {
      Test = cfg.healthcheck;
      Interval = 5000000000;
      Timeout = 1000000000 * (cfg.healthTimeout or 5);
      Retries = 10;
      StartPeriod = if service == "studio" then 60000000000 else 10000000000;
    };
  }
  // lib.optionalAttrs (labels != { }) {
    Labels = labels;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  created = "1970-01-01T00:00:00Z";
  # Copy the assembled root directly into the layer. Keeping store paths out
  # of the image is essential: the runtime contract is a portable rootfs, not
  # a Nix installation with a closure hidden under /nix/store.
  contents = [ ];
  includeStorePaths = false;
  extraCommands = ''
    cp -a ${imageRoot}/. .
    find . -type d -exec chmod 0755 {} +
    find . -type f -perm -0100 -exec chmod 0755 {} +
    find . -type f ! -perm -0100 -exec chmod 0644 {} +
    chmod 1777 tmp
  '';
  fakeRootCommands =
    lib.optionalString
      (
        service == "postgres"
        || service == "storage"
        || service == "edge-runtime"
        || ((cfg.user or "") == "65532:65532")
      )
      ''
        ${lib.optionalString (service == "postgres") ''
          chown -R ${toString (identity.uid or 0)}:${toString (identity.gid or 0)} opt/postgres
          chown ${toString (identity.uid or 0)}:${toString (identity.gid or 0)} var/lib/postgresql/data run/postgresql etc/postgresql etc/postgresql/postgresql.conf
          chmod ${identity.mode or "0700"} var/lib/postgresql/data
          chmod 2775 run/postgresql
        ''}
        ${lib.optionalString (service == "storage") ''
          mkdir -p mnt
          chown ${toString (identity.uid or 0)}:${toString (identity.gid or 0)} mnt
          chmod ${identity.mode or "0755"} mnt
        ''}
        ${lib.optionalString (service == "edge-runtime") ''
          chmod ${identity.mode or "0755"} root
        ''}
        ${lib.optionalString ((cfg.user or "") == "65532:65532") ''
          chown -R 65532:65532 ${lib.removePrefix "/" (cfg.root or ".")}
          chown -R 65532:65532 home/nonroot
        ''}
      '';
  config = config;
}
