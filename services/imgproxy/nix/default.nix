{
  pkgs,
  serviceVersion,
  sourceRepository,
  sourceCommit,
  sourceHash,
  vendorHash,
}:
let
  lib = pkgs.lib;
  version = lib.removePrefix "v" serviceVersion;
  sourceRepositoryParts = lib.splitString "/" sourceRepository;
  sourceOwner =
    if builtins.length sourceRepositoryParts == 2 then
      lib.elemAt sourceRepositoryParts 0
    else
      throw "imgproxy: sourceRepository must be OWNER/REPOSITORY";
  sourceRepo =
    if builtins.length sourceRepositoryParts == 2 then
      lib.elemAt sourceRepositoryParts 1
    else
      throw "imgproxy: sourceRepository must be OWNER/REPOSITORY";
  portableVips =
    (pkgs.vips.override {
      # Keep the codec surface exercised by smoke (JPEG/PNG/WebP/GIF/AVIF), but
      # turn off optional loaders that otherwise drag in a large unrelated
      # closure (AWS, SQLite, OpenEXR, TIFF, PDF, and scientific formats).
      cfitsio = null;
      fftw = null;
      imagemagick = null;
      libarchive = null;
      libjxl = null;
      matio = null;
      openexr = null;
      openjpeg = null;
      openslide = null;
      pango = null;
      poppler = null;
      librsvg = null;
      libtiff = null;
    }).overrideAttrs
      (old: {
        mesonFlags =
          (old.mesonFlags or [ ])
          ++ (map (name: lib.mesonEnable name false) [
            "cfitsio"
            "fftw"
            "archive"
            "jpeg-xl"
            "matio"
            "openexr"
            "openjpeg"
            "openslide"
            "pangocairo"
            "poppler"
            "rsvg"
            "tiff"
            "magick"
            "fontconfig"
          ]);
      });
  vipsBin = lib.getBin portableVips;
  vipsLib = lib.getLib portableVips;

  # Keep the dependency/license manifest generated from the same pinned
  # nixpkgs packages that are linked into the artifact. The shell phase copies
  # every upstream license file from these source trees/archives verbatim.
  mozillaMpl = pkgs.fetchurl {
    url = "https://www.mozilla.org/media/MPL/2.0/index.815ca599c9df.txt";
    sha256 = "119yhq9hlfpq2qn0w0hybvnb9z0igs8xvc9hhv0g29mjv9mxvczs";
  };
  cacertLicense = pkgs.runCommand "cacert-license" { } ''
    mkdir -p $out
    cp ${mozillaMpl} $out/LICENSE
  '';
  licenseDeps = [
    {
      name = "libvips";
      version = "8.16.1";
      spdx = "LGPL-2.1-or-later";
      src = portableVips.src;
    }
    {
      name = "glib";
      spdx = "LGPL-2.1-or-later";
      src = pkgs.glib.src;
    }
    {
      name = "libheif";
      spdx = "LGPL-3.0-or-later";
      src = pkgs.libheif.src;
    }
    {
      name = "libaom";
      spdx = "BSD-2-Clause";
      src = pkgs.libaom.src;
    }
    {
      name = "libde265";
      spdx = "LGPL-3.0-or-later";
      src = pkgs.libde265.src;
    }
    {
      name = "x265";
      spdx = "GPL-2.0-or-later";
      src = pkgs.x265.src;
    }
    {
      name = "libvmaf";
      spdx = "BSD-2-Clause-Patent";
      src = pkgs.libvmaf.src;
    }
    {
      name = "libjpeg";
      spdx = "IJG";
      src = pkgs.libjpeg.src;
    }
    {
      name = "libspng";
      spdx = "BSD-2-Clause";
      src = pkgs.libspng.src;
    }
    {
      name = "libwebp";
      spdx = "BSD-3-Clause";
      src = pkgs.libwebp.src;
    }
    {
      name = "cgif";
      spdx = "MIT";
      src = pkgs.cgif.src;
    }
    {
      name = "libexif";
      spdx = "LGPL-2.1-or-later";
      src = pkgs.libexif.src;
    }
    {
      name = "libimagequant";
      spdx = "GPL-3.0-or-later";
      src = pkgs.libimagequant.src;
    }
    {
      name = "lcms2";
      spdx = "MIT";
      src = pkgs.lcms2.src;
    }
    {
      name = "expat";
      spdx = "MIT";
      src = pkgs.expat.src;
    }
    {
      name = "zlib";
      spdx = "Zlib";
      src = pkgs.zlib.src;
    }
    {
      name = "libffi";
      spdx = "MIT";
      src = pkgs.libffi.src;
    }
    {
      name = "pcre2";
      spdx = "BSD-3-Clause";
      src = pkgs.pcre2.src;
    }
    {
      name = "cacert";
      spdx = "MPL-2.0";
      src = cacertLicense;
    }
  ]
  ++ lib.optionals pkgs.stdenv.isDarwin [
    {
      name = "libcxx";
      spdx = "Apache-2.0 WITH LLVM-exception";
      src = pkgs.libcxx.src;
    }
    {
      name = "libresolv";
      spdx = "APSL-1.0";
      src = pkgs.darwin.libresolv.src;
    }
    {
      name = "libiconv";
      spdx = [
        "BSD-2-Clause"
        "BSD-3-Clause"
        "APSL-1.0"
      ];
      src = pkgs.libiconv.src;
    }
    {
      name = "libintl";
      spdx = "LGPL-2.1-or-later";
      src = pkgs.gettext.src;
    }
  ]
  ++ lib.optionals pkgs.stdenv.isLinux [
    # Linux artifacts carry both glibc and its target loader; preserve the
    # authoritative source license for that bundled runtime rather than
    # claiming it is supplied by the host.
    {
      name = "glibc";
      spdx = "LGPL-2.1-or-later";
      src = pkgs.glibc.src;
    }
    {
      name = "util-linux";
      spdx = "LGPL-2.1-or-later AND GPL-2.0-or-later";
      src = pkgs.util-linux.src;
    }
    {
      name = "libselinux";
      spdx = "LicenseRef-Public-Domain";
      src = pkgs.libselinux.src;
    }
    {
      name = "libnuma";
      spdx = "LGPL-2.1-or-later";
      src = pkgs.numactl.src;
    }
    {
      name = "gcc-runtime";
      spdx = "GPL-3.0-or-later WITH GCC-exception-3.1";
      src = pkgs.gcc.cc.src;
    }
  ];
  licenseManifest = pkgs.writeText "imgproxy-dependency-licenses.json" (
    builtins.toJSON {
      format = 1;
      description = "License manifest generated from the pinned nixpkgs runtime closure; SPDX claims follow the bundled component source texts.";
      dependencies = map (
        d: (builtins.removeAttrs d [ "src" ]) // { license_dir = "share/licenses/${d.name}"; }
      ) licenseDeps;
    }
  );
  licenseCopyCommands = lib.concatMapStringsSep "\n" (
    d: "copy_licenses ${lib.escapeShellArg d.name} ${lib.escapeShellArg (toString d.src)}"
  ) licenseDeps;

  src = pkgs.fetchFromGitHub {
    owner = sourceOwner;
    repo = sourceRepo;
    rev = sourceCommit;
    hash = sourceHash;
  };

  # This probe exposes buildGoModule's own fixed-output vendor derivation. A
  # source-lock hook can build -A goModules with fakeHash to discover the
  # current vendor hash without evaluating/building libvips or the rootfs.
  goModulesProbe = pkgs.buildGoModule {
    pname = "imgproxy-go-modules-probe";
    inherit version src;
    vendorHash = lib.fakeHash;
    doCheck = false;
  };
  goModules = goModulesProbe.goModules;

  # The upstream Go module uses the C vips API. Keeping vips as a native
  # nixpkgs dependency gives us the exact 8.16.1 codec/plugin set on each
  # target platform while buildGoModule remains the reproducible source build.
  imgproxyBin = pkgs.buildGoModule {
    pname = "imgproxy";
    inherit version src;
    inherit vendorHash;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [
      portableVips
      pkgs.libunwind
    ];
    env.CGO_ENABLED = 1;
    subPackages = [ "." ];
    ldflags = [
      "-s"
      "-w"
    ];
    doCheck = false;
  };

  rootfs = pkgs.stdenv.mkDerivation {
    pname = "imgproxy-portable";
    inherit version;
    dontUnpack = true;
    dontPatchShebangs = true;
    dontStrip = true;
    # The build phase performs the complete relocation itself. Generic Nix
    # fixup would shrink plugin RPATHs against the build store and restore
    # those absolute paths after our closure rewrite.
    dontFixup = true;
    nativeBuildInputs = [
      pkgs.file
      pkgs.python3
      pkgs.makeWrapper
    ]
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ]
    ++ lib.optionals pkgs.stdenv.isDarwin [ pkgs.darwin.cctools ];

    buildPhase = ''
            set -euo pipefail
            rootfs="$out"
            mkdir -p "$rootfs/bin" "$rootfs/lib" "$rootfs/libexec" "$rootfs/share/licenses"
            cp ${imgproxyBin}/bin/imgproxy "$rootfs/bin/.imgproxy-real"
            chmod 0755 "$rootfs/bin/.imgproxy-real"
            mkdir -p "$rootfs/share/licenses/imgproxy"
            cp ${src}/LICENSE "$rootfs/share/licenses/imgproxy/LICENSE"
            cp ${src}/NOTICE "$rootfs/share/licenses/imgproxy/NOTICE"
            # Keep a small vips diagnostic tool in the artifact. It is used by the
            # integration proof to report the actual loader/module support shipped.
            cp ${vipsBin}/bin/vips "$rootfs/libexec/vips"
            chmod 0755 "$rootfs/libexec/vips"

            # JPEG/PNG/WebP/GIF loaders are built into libvips. Only AVIF/HEIF is a
            # dynamic module in the promised codec set; copying every optional vips
            # module would pull unrelated AWS, SQLite, Kerberos, and image stacks.
            mkdir -p "$rootfs/lib/vips-modules-8.16"
            if [ -f ${vipsLib}/lib/vips-modules-8.16/vips-heif.dylib ]; then
              cp -L ${vipsLib}/lib/vips-modules-8.16/vips-heif.dylib "$rootfs/lib/vips-modules-8.16/"
            elif [ -f ${vipsLib}/lib/vips-modules-8.16/vips-heif.so ]; then
              cp -L ${vipsLib}/lib/vips-modules-8.16/vips-heif.so "$rootfs/lib/vips-modules-8.16/"
            fi
            [ ! -f "$rootfs/lib/vips-modules-8.16/vips-heif.so" ] || chmod u+w "$rootfs/lib/vips-modules-8.16/vips-heif.so"

            # Runtime side data needed by vips/fontconfig and HTTP clients.
            mkdir -p "$rootfs/share/gio-modules" "$rootfs/etc/ssl/certs"
            cp ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$rootfs/etc/ssl/certs/ca-certificates.crt"

            # Copy the actual license texts from each source used by the realized
            # codec closure. Archives are unpacked transiently; the artifact keeps
            # only license files, grouped by dependency.
            copy_licenses() {
              dep="$1"; source="$2"; dest="$rootfs/share/licenses/$dep"
              mkdir -p "$dest"
              scan="$source"; tmp=""; found=""
              if [ -f "$source" ]; then
                case "$source" in
                  *.tar|*.tar.*|*.tgz)
                    tmp="$(mktemp -d)"
                    tar -xf "$source" -C "$tmp"
                    scan="$tmp"
                    ;;
                  *) found="$source" ;;
                esac
              elif [ ! -d "$scan" ]; then
                tmp="$(mktemp -d)"
                tar -xf "$scan" -C "$tmp"
                scan="$tmp"
              fi
              if [ -z "$found" ]; then
                found="$(find "$scan" -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'NOTICE*' -o -iname 'COPYRIGHT*' \) -print | sort)"
              fi
              if [ -z "$found" ]; then
                # Some platform runtimes (notably Apple's libiconv) carry their
                # license in source-file headers rather than a central COPYING.
                found="$(grep -RIl -E 'SPDX-License-Identifier|Redistribution and use|Apple Public Source License' "$scan" 2>/dev/null | sort | head -40)"
              fi
              [ -n "$found" ] || { echo "no license text found for $dep" >&2; exit 1; }
              first=1
              : > "$dest/LICENSES.txt"
              while IFS= read -r file; do
                if [ "$first" = 1 ]; then
                  cp "$file" "$dest/LICENSE"
                  first=0
                fi
                {
                  printf '\n===== %s =====\n' "$(basename "$file")"
                  cat "$file"
                } >> "$dest/LICENSES.txt"
              done <<EOF_LICENSES
      $found
      EOF_LICENSES
              [ -z "$tmp" ] || rm -rf "$tmp"
            }
            ${licenseCopyCommands}
            cp ${licenseManifest} "$rootfs/share/licenses/dependency-licenses.json"

            # Resolve the complete dynamic closure from the actual binary, vips CLI,
            # and every plugin. A basename collision would make one dependency win
            # nondeterministically after relocation, so fail loudly instead.
            macho_files() {
              find "$rootfs/bin" "$rootfs/lib" "$rootfs/libexec" -type f -print | while IFS= read -r candidate; do
                file "$candidate" | grep -q 'Mach-O' && printf '%s\n' "$candidate"
              done
            }
            elf_files() {
              find "$rootfs/bin" "$rootfs/lib" "$rootfs/libexec" -type f -print | while IFS= read -r candidate; do
                file "$candidate" | grep -q 'ELF' && printf '%s\n' "$candidate"
              done
            }
            copy_dep() {
              dep="$1"
              new_copy=0
              [ -e "$dep" ] || return 0
              name="$(basename "$dep")"
              if [ "$(uname -s)" = Darwin ]; then
                # Different vips split outputs can carry the same install-name
                # basename (notably libwebp). Keep both files and use the Nix store
                # hash as a deterministic local suffix; Mach-O load commands below
                # are rewritten to this exact filename.
                store_hash="$(basename "$(dirname "$(dirname "$dep")")" | cut -c1-12)"
                name="$name-$store_hash"
              fi
              dest="$rootfs/lib/$name"
              if [ -e "$dest" ]; then
                existing_hash="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$dest" | awk '{print $1}')"
                incoming_hash="$(sha256sum "$dep" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$dep" | awk '{print $1}')"
                [ "$existing_hash" = "$incoming_hash" ] || { echo "dependency basename collision: $name" >&2; exit 1; }
                return 0
              fi
              cp -L "$dep" "$dest"
              chmod u+w "$dest"
              new_copy=1
            }

            if [ "$(uname -s)" = Darwin ]; then
              nix_store_deps() { otool -L "$1" 2>/dev/null | awk 'NR > 1 && $1 ~ /^\/nix\/store\// { print $1 }'; }
              for iteration in 1 2 3 4 5 6 7 8; do
                copied=0
                for macho in $(macho_files); do
                  for dep in $(nix_store_deps "$macho"); do
                    copy_dep "$dep"
                    [ "$new_copy" = 1 ] && copied=1
                  done
                done
                [ "$copied" = 0 ] && break
              done
              for macho in $(macho_files); do
                rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$rootfs/lib" "$macho")"
                case "$macho" in
                  "$rootfs/lib"/*) install_name_tool -id "@rpath/$(basename "$macho")" "$macho" 2>/dev/null || true ;;
                esac
                changed=0
                for dep in $(nix_store_deps "$macho"); do
                  name="$(basename "$dep")-$(basename "$(dirname "$(dirname "$dep")")" | cut -c1-12)"
                  if [ -e "$rootfs/lib/$name" ]; then
                    install_name_tool -change "$dep" "@rpath/$name" "$macho" 2>/dev/null || true
                    changed=1
                  fi
                done
                [ "$changed" = 1 ] && install_name_tool -add_rpath "@loader_path/$rel" "$macho" 2>/dev/null || true
                otool -l "$macho" 2>/dev/null | awk '$1 == "cmd" && $2 == "LC_RPATH" { in_rpath=1; next } in_rpath && $1 == "path" { print $2; in_rpath=0 }' | while IFS= read -r rpath; do
                  case "$rpath" in /nix/store/*) install_name_tool -delete_rpath "$rpath" "$macho" 2>/dev/null || true ;; esac
                done
                strip -x "$macho" 2>/dev/null || true
                codesign --force --sign - "$macho" 2>/dev/null || true
              done
              unresolved="$(for macho in $(macho_files); do otool -L "$macho" 2>/dev/null | awk -v f="$macho" 'NR > 1 && $1 ~ /^\/nix\/store\// { print f " -> " $1 }'; done)"
              [ -z "$unresolved" ] || { echo "$unresolved" >&2; exit 1; }
            else
              case "$(uname -m)" in
                aarch64) interp=/lib/ld-linux-aarch64.so.1; loader_name=ld-linux-aarch64.so.1 ;;
                x86_64) interp=/lib64/ld-linux-x86-64.so.2; loader_name=ld-linux-x86-64.so.2 ;;
                *) echo "unsupported linux arch" >&2; exit 1 ;;
              esac
              nix_store_deps() { ldd "$1" 2>/dev/null | awk '/=> \/nix\/store/ { print $3 } $1 ~ /^\/nix\/store/ { print $1 }'; }
              for iteration in 1 2 3 4 5 6 7 8; do
                copied=0
                for elf in $(elf_files); do
                  for dep in $(nix_store_deps "$elf"); do
                    copy_dep "$dep"
                    [ "$new_copy" = 1 ] && copied=1
                  done
                done
                [ "$copied" = 0 ] && break
              done
              for elf in $(elf_files); do
                # The dynamic loader is itself a static-pie ELF entry point. Running
                # patchelf/strip on it corrupts its bootstrap state and causes an
                # immediate SIGSEGV before any wrapped binary can start.
                [ "$(basename "$elf")" = "$loader_name" ] && continue
                rel="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$rootfs/lib" "$elf")"
                patchelf --set-rpath "\$ORIGIN/$rel" "$elf" 2>/dev/null || { echo "patchelf rpath failed for $elf" >&2; exit 1; }
                patchelf --set-interpreter "$interp" "$elf" 2>/dev/null || true
                strip --strip-unneeded "$elf" 2>/dev/null || true
              done
            fi

            if [ "$(uname -s)" = Linux ]; then
              case "$(uname -m)" in aarch64) loader_name=ld-linux-aarch64.so.1 ;; x86_64) loader_name=ld-linux-x86-64.so.2 ;; *) echo "unsupported linux arch" >&2; exit 1 ;; esac
              [ -x "$rootfs/lib/$loader_name" ] || { echo "bundled loader missing: $loader_name" >&2; exit 1; }
            else
              loader_name=""
            fi

            cat > "$rootfs/bin/imgproxy" <<'EOF'
      #!/bin/sh
      set -eu
      ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
      export VIPSHOME="''${VIPSHOME:-$ROOT}"
      export VIPS_MODULE_PATH="''${VIPS_MODULE_PATH:-$ROOT/lib/vips-modules-8.16}"
      export GIO_MODULE_DIR="''${GIO_MODULE_DIR:-$ROOT/share/gio-modules}"
      export VIPS_WARNING="''${VIPS_WARNING:-0}"
      export SSL_CERT_FILE="''${SSL_CERT_FILE:-$ROOT/etc/ssl/certs/ca-certificates.crt}"
      if [ -n "IMGPROXY_LOADER" ]; then
        if [ ! -x "$ROOT/lib/IMGPROXY_LOADER" ]; then
          echo "imgproxy: bundled loader missing: $ROOT/lib/IMGPROXY_LOADER" >&2
          exit 127
        fi
        export LD_LIBRARY_PATH="$ROOT/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        exec "$ROOT/lib/IMGPROXY_LOADER" --library-path "$ROOT/lib" "$ROOT/bin/.imgproxy-real" "$@"
      fi
      export DYLD_LIBRARY_PATH="$ROOT/lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
      exec "$ROOT/bin/.imgproxy-real" "$@"
      EOF
            sed -i "s|IMGPROXY_LOADER|$loader_name|g" "$rootfs/bin/imgproxy"
            chmod 0755 "$rootfs/bin/imgproxy"

            cat > "$rootfs/bin/vips" <<'EOF'
      #!/bin/sh
      set -eu
      ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
      export VIPSHOME="''${VIPSHOME:-$ROOT}"
      export VIPS_MODULE_PATH="''${VIPS_MODULE_PATH:-$ROOT/lib/vips-modules-8.16}"
      export GIO_MODULE_DIR="''${GIO_MODULE_DIR:-$ROOT/share/gio-modules}"
      if [ -n "IMGPROXY_LOADER" ]; then
        if [ ! -x "$ROOT/lib/IMGPROXY_LOADER" ]; then
          echo "vips: bundled loader missing: $ROOT/lib/IMGPROXY_LOADER" >&2
          exit 127
        fi
        export LD_LIBRARY_PATH="$ROOT/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        exec "$ROOT/lib/IMGPROXY_LOADER" --library-path "$ROOT/lib" "$ROOT/libexec/vips" "$@"
      fi
      export DYLD_LIBRARY_PATH="$ROOT/lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
      exec "$ROOT/libexec/vips" "$@"
      EOF
            sed -i "s|IMGPROXY_LOADER|$loader_name|g" "$rootfs/bin/vips"
            chmod 0755 "$rootfs/bin/vips"

            cat > "$rootfs/runtime-manifest.json" <<EOF
      {"service":"imgproxy","version":"$version","upstream_repository":"${sourceRepository}","upstream_commit":"${sourceCommit}","source_hash":"${sourceHash}","vendor_hash":"${vendorHash}","nixpkgs_commit":"ac62194c3917d5f474c1a844b6fd6da2db95077d","vips":"8.16.1","codecs":["jpeg","png","webp","gif","avif"],"runtime":{"wrapper":"bin/imgproxy","real_binary":"bin/.imgproxy-real","vips_wrapper":"bin/vips","vips_real":"libexec/vips","module_path":"lib/vips-modules-8.16","gio_module_dir":"share/gio-modules","ca_bundle":"etc/ssl/certs/ca-certificates.crt"},"licenses":["share/licenses/imgproxy","share/licenses/dependency-licenses.json"]}
      EOF
    '';

    installPhase = "true";
  };
in
{
  inherit goModules;
  imgproxy = rootfs;
}
