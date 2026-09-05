#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact-from-image.sh SERVICE [VERSION]

Extract the paths listed in services/SERVICE/recipe.env from SOURCE_IMAGE into
the common artifact layout. SOURCE_IMAGE and VERSION can be overridden through
environment variables.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd docker
require_cmd tar
require_cmd python3

service="$1"
VERSION="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
PLATFORM="${PLATFORM:-$(docker_platform "$TARGET_OS" "$ARCH")}"

load_recipe "$service"

SOURCE_IMAGE="${SOURCE_IMAGE:?recipe must define SOURCE_IMAGE}"
BASE_IMAGE="${BASE_IMAGE:?recipe must define BASE_IMAGE}"
ENTRYPOINT_JSON="${ENTRYPOINT_JSON:?recipe must define ENTRYPOINT_JSON}"
CMD_JSON="${CMD_JSON:-[]}"

artifact_dir="$ROOT_DIR/artifacts/$service/$VERSION/$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"
sbom="$artifact_dir/$service-$VERSION-$(artifact_platform_dir "$TARGET_OS" "$ARCH").sbom.spdx.json"

rm -rf "$rootfs"
mkdir -p "$rootfs" "$artifact_dir"

log "extracting $service artifact from $SOURCE_IMAGE for $PLATFORM"
cid="$(docker create --platform "$PLATFORM" "$SOURCE_IMAGE")"
cleanup_container() {
  docker rm -f "$cid" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT

copy_container_path() {
  local path="$1"
  local required="$2"
  [[ "$path" = /* ]] || fail "INCLUDE_PATHS entries must be absolute: $path"
  parent="$rootfs$(dirname "$path")"
  mkdir -p "$parent"
  log "copying $path"
  if ! docker cp "$cid:$path" "$parent/" 2>/dev/null; then
    if [[ "$required" == "required" ]]; then
      fail "required path not found in $SOURCE_IMAGE: $path"
    fi
    log "optional path not found, skipping: $path"
  fi
}

for path in "${INCLUDE_PATHS[@]}"; do
  copy_container_path "$path" required
done

if declare -p OPTIONAL_INCLUDE_PATHS >/dev/null 2>&1; then
  for path in "${OPTIONAL_INCLUDE_PATHS[@]}"; do
    copy_container_path "$path" optional
  done
fi

if [[ "${AUTO_ELF_DEPS:-false}" == "true" ]]; then
  if ! declare -p AUTO_ELF_BINARIES >/dev/null 2>&1; then
    fail "AUTO_ELF_DEPS=true requires AUTO_ELF_BINARIES in the recipe"
  fi

  # Statically linked binaries have no deps to collect, and their images may
  # not even carry a shell for the docker run below (postgrest amd64 is a
  # lone static binary).
  elf_list=""
  for binary in "${AUTO_ELF_BINARIES[@]}"; do
    if file "$rootfs$binary" 2>/dev/null | grep -q 'statically linked'; then
      log "skipping ELF dependency collection for statically linked $binary"
      continue
    fi
    elf_list="${elf_list}${binary}"$'\n'
  done
fi

if [[ -n "${elf_list:-}" ]]; then
  log "collecting ELF dependencies from $SOURCE_IMAGE"
  docker run --rm --platform "$PLATFORM" \
    --user 0:0 \
    --entrypoint /bin/sh \
    -v "$rootfs:/artifact-rootfs" \
    -e "AUTO_ELF_BINARIES=$elf_list" \
    "$SOURCE_IMAGE" \
    -lc '
      set -eu

      copy_path() {
        src="$1"
        [ -e "$src" ] || return 0
        dst="/artifact-rootfs$src"
        mkdir -p "$(dirname "$dst")"
        cp -aL "$src" "$dst"
      }

      printf "%s\n" "$AUTO_ELF_BINARIES" | while IFS= read -r binary; do
        [ -n "$binary" ] || continue
        [ -x "$binary" ] || {
          echo "ELF binary not found or not executable: $binary" >&2
          exit 1
        }

        ldd "$binary" | awk '\''
          /=> \// { print $3; next }
          /^[[:space:]]*\// { print $1; next }
        '\'' | while IFS= read -r dep; do
          [ -n "$dep" ] || continue
          copy_path "$dep"
        done
      done
    '
fi

# Some ELF-deps closures bundle their own glibc family (libc/libm/loader/...)
# alongside their non-glibc deps in one directory. Run bare on a host, the
# dynamic loader looks for that glibc family at its own standard search path
# (lib/<triplet>), not wherever the closure happens to keep it — so split the
# glibc family out into lib/<triplet> and rpath the binaries at the
# non-glibc closure dir. This keeps both contracts working without env vars:
# a bare host run gets a matched host-loader/host-glibc pair plus the
# bundled non-glibc deps via rpath, and the scratch Docker image (which has
# no host glibc to fall back to) finds the bundled loader+glibc at the
# standard path and the rest via rpath. Requires patchelf, which only runs
# on Linux, so this happens inside the SOURCE_IMAGE-derived container, never
# on the macOS build host.
if [[ "${SPLIT_BUNDLED_GLIBC:-false}" == "true" && -n "${elf_list:-}" ]]; then
  log "splitting bundled glibc runtime out of the ELF-deps closure for $service"
  docker run --rm --platform "$PLATFORM" \
    --user 0:0 \
    --entrypoint /bin/sh \
    -v "$rootfs:/artifact-rootfs" \
    -e "AUTO_ELF_BINARIES=$elf_list" \
    "$SOURCE_IMAGE" \
    -lc '
      set -eu

      apt-get -qq update >/dev/null 2>&1
      apt-get -qq install -y patchelf >/dev/null 2>&1
      command -v patchelf >/dev/null 2>&1 || {
        echo "patchelf unavailable in the SOURCE_IMAGE-derived container (apt-get install failed)" >&2
        exit 1
      }

      triplet="$(uname -m)-linux-gnu"
      bundle_dir="/artifact-rootfs/usr/lib/$triplet"
      glibc_dir="/artifact-rootfs/lib/$triplet"

      if [ -d "$bundle_dir" ]; then
        mkdir -p "$glibc_dir"
        for pattern in \
          "libc.so*" "libc-*.so*" "libm.so*" "libm-*.so*" "libmvec.so*" \
          "libpthread.so*" "libpthread-*.so*" "libdl.so*" "libdl-*.so*" \
          "libresolv.so*" "libresolv-*.so*" "librt.so*" "librt-*.so*" \
          "libutil.so*" "libutil-*.so*" "libnss_*.so*" "libanl.so*" \
          "libthread_db.so*" "libnsl.so*" "libBrokenLocale.so*" "ld-linux*.so*"
        do
          for f in "$bundle_dir"/$pattern; do
            [ -e "$f" ] || continue
            mv "$f" "$glibc_dir/"
          done
        done
      fi

      # DT_RUNPATH is not transitive: it only guides resolution of the
      # object that carries it, not of that object'\''s own dependencies.
      # libpq.so.5 needs libgssapi_krb5.so.2 et al from the same bundle dir,
      # so every shared object left in the bundle dir needs its own
      # self-referencing rpath too, not just the main binary.
      if [ -d "$bundle_dir" ]; then
        for so in "$bundle_dir"/*.so*; do
          [ -e "$so" ] || continue
          patchelf --set-rpath '\''$ORIGIN'\'' "$so"
        done
      fi

      printf "%s\n" "$AUTO_ELF_BINARIES" | while IFS= read -r binary; do
        [ -n "$binary" ] || continue
        target="/artifact-rootfs$binary"
        [ -e "$target" ] || {
          echo "rpath target not found: $binary" >&2
          exit 1
        }
        patchelf --set-rpath "\$ORIGIN/../usr/lib/$triplet" "$target"
      done
    '
fi

# A service may need a small, service-owned transformation after image
# extraction has collected and repaired its ELF closure.  Keep this hook
# optional and fail loud: the transformed rootfs is what the subsequent
# prune, SBOM, archive, and CI audit consume.  The script receives the staged
# rootfs as its sole argument and must be executable.
if [[ -n "${ARTIFACT_POSTPROCESS_SCRIPT:-}" ]]; then
  postprocess_script="$ARTIFACT_POSTPROCESS_SCRIPT"
  [[ "$postprocess_script" = /* ]] || postprocess_script="$ROOT_DIR/$postprocess_script"
  [[ -x "$postprocess_script" ]] || fail "artifact postprocess script is missing or not executable: $postprocess_script"
  log "running artifact postprocess script for $service"
  "$postprocess_script" "$rootfs"
fi

if [[ -n "${WRAPPED_BINARY_SOURCE:-}" && -n "${WRAPPED_BINARY_DEST:-}" ]]; then
  [[ -e "$rootfs$WRAPPED_BINARY_SOURCE" ]] || fail "wrapped binary source was not copied: $WRAPPED_BINARY_SOURCE"
  mkdir -p "$rootfs$(dirname "$WRAPPED_BINARY_DEST")"
  mv "$rootfs$WRAPPED_BINARY_SOURCE" "$rootfs$WRAPPED_BINARY_DEST"
  chmod 0755 "$rootfs$WRAPPED_BINARY_DEST"
fi

if [[ -f "$(service_dir "$service")/wrapper.sh" ]]; then
  wrapper_path="${WRAPPER_PATH:-/usr/local/bin/$service}"
  mkdir -p "$rootfs$(dirname "$wrapper_path")"
  cp "$(service_dir "$service")/wrapper.sh" "$rootfs$wrapper_path"
  chmod 0755 "$rootfs$wrapper_path"
fi

"$ROOT_DIR/scripts/prune-runtime-tree.sh" "$rootfs"
"$ROOT_DIR/scripts/generate-artifact-sbom.sh" \
  "$rootfs" "$sbom" "$service" "$VERSION" \
  "$(artifact_platform_dir "$TARGET_OS" "$ARCH")"

archive=""
archive_bytes="None"
if [[ "${ARTIFACT_ARCHIVE_ON_BUILD:-1}" == "1" ]]; then
  archive="$(archive_runtime "$rootfs" "$artifact_dir/$service")"
  archive_bytes="$(wc -c < "$archive" | tr -d ' ')"
fi

rootfs_kib="$(du -sk "$rootfs" | awk '{print $1}')"

portable="$(portable_flag)"
assumed_host_libs_json="$(portable_host_libs_json)"

python3 - "$manifest" <<PY
import json
import os

manifest = {
    "service": "$service",
    "version": "$VERSION",
    "platform": "$PLATFORM",
    "arch": "$ARCH",
    "target": "$(artifact_platform_dir "$TARGET_OS" "$ARCH")",
    "libc": "glibc" if "$TARGET_OS" == "linux" else None,
    "source_image": "$SOURCE_IMAGE",
    "base_image": "$BASE_IMAGE",
    "entrypoint": json.loads("""$ENTRYPOINT_JSON"""),
    "cmd": json.loads("""$CMD_JSON"""),
    "build_backend": "image",
    "include_paths": ${INCLUDE_PATHS_JSON:-[]},
    "auto_elf_deps": "$AUTO_ELF_DEPS" == "true",
    "auto_elf_binaries": ${AUTO_ELF_BINARIES_JSON:-[]},
    "split_bundled_glibc": "${SPLIT_BUNDLED_GLIBC:-false}" == "true",
    "portable": "$portable" == "true",
    "assumed_host_libs": json.loads("""$assumed_host_libs_json"""),
    "excluded_file_classes": [
        "sourcemaps",
        "debug-symbols",
        "tests",
        "docs",
        "examples",
        "package-manager-caches",
        "Next tracing manifests"
    ],
    "smoke_command": "scripts/smoke.sh $service --artifact $rootfs",
    "archive": os.path.basename("$archive") or None,
    "sbom": os.path.basename("$sbom"),
    "licenses": "share/licenses",
    "size": {
        "rootfs_bytes": int($rootfs_kib) * 1024,
        "rootfs_mib": round((int($rootfs_kib) * 1024) / 1024 / 1024, 1),
        "archive_bytes": $archive_bytes,
        "archive_mib": round($archive_bytes / 1024 / 1024, 1) if $archive_bytes is not None else None
    }
}

with open("$manifest", "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\\n")
PY

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" ${archive:+"$archive"}
log "artifact ready: $artifact_dir"
