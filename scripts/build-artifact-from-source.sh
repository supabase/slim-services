#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact-from-source.sh SERVICE [VERSION]

Build SERVICE from its sources/SERVICE git submodule using
services/SERVICE/Dockerfile.artifact or ARTIFACT_DOCKERFILE from the recipe,
then write the common artifact layout:

  artifacts/<service>/<version>/<target-os>-<arch>/rootfs/
  artifacts/<service>/<version>/<target-os>-<arch>/<service>.tar.zst
  artifacts/<service>/<version>/<target-os>-<arch>/manifest.json
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd git
require_cmd tar
require_cmd python3

service="$1"
VERSION="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
if [[ "$TARGET_OS" == "linux" ]]; then
  PLATFORM="${PLATFORM:-$(docker_platform "$TARGET_OS" "$ARCH")}"
else
  PLATFORM="${PLATFORM:-$TARGET_OS/$ARCH}"
fi

load_recipe "$service"

# SOURCE_DIR is optional: recipes with ARTIFACT_BACKEND=docker-image build their
# Dockerfile.artifact from an upstream image (SOURCE_IMAGE) with no submodule.
SOURCE_DIR="${SOURCE_DIR:-}"
BASE_IMAGE="${BASE_IMAGE:?recipe must define BASE_IMAGE}"
ENTRYPOINT_JSON="${ENTRYPOINT_JSON:?recipe must define ENTRYPOINT_JSON}"
CMD_JSON="${CMD_JSON:-[]}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-${SOURCE_IMAGE:-}}"

artifact_dockerfile="${ARTIFACT_DOCKERFILE:-Dockerfile.artifact}"
dockerfile="$ROOT_DIR/services/$service/$artifact_dockerfile"
artifact_dir="$ROOT_DIR/artifacts/$service/$VERSION/$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"
sbom="$artifact_dir/$service-$VERSION-$(artifact_platform_dir "$TARGET_OS" "$ARCH").sbom.spdx.json"

# Non-linux targets always build with services/<service>/build-host.sh (no
# Docker on macOS CI runners); linux targets do too when the recipe opts in
# with ARTIFACT_SOURCE_BUILD="host" (native-first services whose build is a
# plain host toolchain, e.g. Go cross-compiles and Node bundles).
use_host_build=0
if [[ "$TARGET_OS" != "linux" || "${ARTIFACT_SOURCE_BUILD:-docker}" == "host" ]]; then
  use_host_build=1
fi

if [[ "$use_host_build" == "0" ]]; then
  require_cmd docker
  [[ -f "$dockerfile" ]] || fail "artifact Dockerfile not found: $dockerfile"
fi

actual_ref=""
build_mode="image-dockerfile"
if [[ -n "$SOURCE_DIR" ]]; then
  build_mode="source-submodule"
  SOURCE_REF="${SOURCE_REF:?recipe must define SOURCE_REF when SOURCE_DIR is set}"
  source_abs="$ROOT_DIR/$SOURCE_DIR"
  [[ -d "$source_abs" ]] || fail "source submodule directory not found: $SOURCE_DIR"
  [[ -f "$source_abs/.git" || -d "$source_abs/.git" ]] || fail "source directory is not a git checkout: $SOURCE_DIR"

  expected_ref="$(resolve_source_ref "$source_abs" "$SOURCE_REF")"
  actual_ref="$(git -C "$source_abs" rev-parse HEAD)"
  if [[ "$actual_ref" != "$expected_ref" ]]; then
    fail "$SOURCE_DIR is at $actual_ref, expected $SOURCE_REF ($expected_ref). Run: git submodule update --init --recursive"
  fi

  if [[ -n "$(git -C "$source_abs" status --short)" ]]; then
    fail "$SOURCE_DIR has local modifications; source artifact builds require clean submodules"
  fi
else
  SOURCE_REF="${SOURCE_REF:-}"
  [[ -n "$UPSTREAM_IMAGE" ]] || fail "recipe must define SOURCE_DIR or SOURCE_IMAGE/UPSTREAM_IMAGE"
fi

# A previous mode-preserving extraction may have left read-only directories
# (Nix store trees); make them deletable before clearing.
if [[ -d "$rootfs" ]]; then
  chmod -R u+w "$rootfs" 2>/dev/null || true
fi
rm -rf "$rootfs"
mkdir -p "$rootfs" "$artifact_dir"

build_args=(
  --build-arg "SERVICE_VERSION=$VERSION"
  --build-arg "BASE_IMAGE=$BASE_IMAGE"
)
if [[ -n "$SOURCE_DIR" ]]; then
  build_args+=(--build-arg "SOURCE_DIR=$SOURCE_DIR")
fi
if [[ -n "${SOURCE_IMAGE:-}" ]]; then
  # Provenance: source-submodule builds are pinned by commit; image-rooted
  # builds should be pinned by digest so a republished upstream tag (or stale
  # local cache) cannot silently change what we build from.
  source_image_ref="$SOURCE_IMAGE"
  if [[ -n "${SOURCE_IMAGE_DIGEST:-}" && "$source_image_ref" != *"@"* ]]; then
    source_image_ref="${source_image_ref}@${SOURCE_IMAGE_DIGEST}"
  elif [[ -z "$SOURCE_DIR" && "$source_image_ref" != *"@"* ]]; then
    log "WARNING: docker-image build without SOURCE_IMAGE_DIGEST; the mutable tag $source_image_ref is the only pin"
  fi
  build_args+=(--build-arg "SOURCE_IMAGE=$source_image_ref")
fi

if declare -p ARTIFACT_BUILD_ARGS >/dev/null 2>&1; then
  for arg in "${ARTIFACT_BUILD_ARGS[@]}"; do
    build_args+=(--build-arg "$arg")
  done
fi

if [[ "$use_host_build" == "1" ]]; then
  # Host-toolchain build: services/<service>/build-host.sh cross-compiles the
  # pinned submodule into ROOTFS with no Docker involved. sources/ stays
  # read-only; the script must write only to ROOTFS.
  host_build="$ROOT_DIR/services/$service/build-host.sh"
  [[ -x "$host_build" ]] || fail "$service has no host build script for $TARGET_OS targets: $host_build"
  [[ -n "$SOURCE_DIR" ]] || fail "host builds require SOURCE_DIR in the recipe"
  build_mode="host-source"
  log "building $service artifact from $SOURCE_DIR@$SOURCE_REF with host toolchain for $TARGET_OS/$ARCH"
  SERVICE="$service" \
    VERSION="$VERSION" \
    TARGET_OS="$TARGET_OS" \
    ARCH="$ARCH" \
    SOURCE_DIR="$source_abs" \
    ROOTFS="$rootfs" \
    ROOT_DIR="$ROOT_DIR" \
    "$host_build"
else
  docker_builder="${DOCKER_BUILDER:-$(docker context show 2>/dev/null || echo default)}"
  log "building $service artifact from ${SOURCE_DIR:-$UPSTREAM_IMAGE}${SOURCE_REF:+@$SOURCE_REF} for $PLATFORM using builder $docker_builder"
  # ARTIFACT_EXPORT=tar streams the artifact stage as a single tarball instead of
  # the per-file local exporter, which can stall on rootfs trees with very large
  # file counts (e.g. the postgres Nix store).
  export_tar=""
  if [[ "${ARTIFACT_EXPORT:-local}" == "tar" ]]; then
    export_tar="$artifact_dir/.rootfs-export.tar"
    rm -f "$export_tar"
    trap 'rm -f "$export_tar"' EXIT
    output_spec="type=tar,dest=$export_tar"
  else
    output_spec="type=local,dest=$rootfs"
  fi

  docker buildx build \
    --builder "$docker_builder" \
    --platform "$PLATFORM" \
    --target artifact \
    --output "$output_spec" \
    -f "$dockerfile" \
    "${build_args[@]}" \
    "$ROOT_DIR"

  if [[ -n "$export_tar" ]]; then
    log "extracting artifact tar export"
    # -p: without it a non-root extraction applies the umask and silently strips
    # mode bits the image relies on (e.g. postgres-writable config dirs).
    tar -C "$rootfs" -xpf "$export_tar"
    rm -f "$export_tar"
  fi
fi

"$ROOT_DIR/scripts/prune-runtime-tree.sh" "$rootfs"
"$ROOT_DIR/scripts/generate-artifact-sbom.sh" \
  "$rootfs" "$sbom" "$service" "$VERSION" \
  "$(artifact_platform_dir "$TARGET_OS" "$ARCH")"

# ci-build-service.sh creates the distribution archive itself; skip the
# duplicate (zstd -19 over the full rootfs) when the caller says so.
archive=""
archive_bytes="None"
if [[ "${ARTIFACT_ARCHIVE_ON_BUILD:-1}" == "1" ]]; then
  archive="$(archive_with_best_available_compressor "$rootfs" "$artifact_dir/$service")"
  archive_bytes="$(wc -c < "$archive" | tr -d ' ')"
fi

rootfs_kib="$(du -sk "$rootfs" | awk '{print $1}')"

portable="$(portable_flag)"
assumed_host_libs_json="$(portable_host_libs_json)"

python3 - "$manifest" <<PY
import json
import os

archive_bytes = $archive_bytes

manifest = {
    "service": "$service",
    "version": "$VERSION",
    "platform": "$PLATFORM",
    "arch": "$ARCH",
    "target": "$(artifact_platform_dir "$TARGET_OS" "$ARCH")",
    "libc": "glibc" if "$TARGET_OS" == "linux" else None,
    "source_dir": "$SOURCE_DIR",
    "source_ref": "$SOURCE_REF",
    "source_commit": "$actual_ref",
    "upstream_image": "$UPSTREAM_IMAGE",
    "upstream_asset_url": os.environ.get("UPSTREAM_ASSET_URL") or None,
    "upstream_asset_sha256": os.environ.get("UPSTREAM_ASSET_SHA256") or None,
    "base_image": "$BASE_IMAGE",
    "entrypoint": json.loads("""$ENTRYPOINT_JSON"""),
    "cmd": json.loads("""$CMD_JSON"""),
    "build_mode": "$build_mode",
    "artifact_dockerfile": "$artifact_dockerfile" if "$use_host_build" != "1" else None,
    "portable": "$portable" == "true",
    "assumed_host_libs": json.loads("""$assumed_host_libs_json"""),
    "runtime_requires": "${RUNTIME_REQUIRES:-}" or None,
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
        "archive_bytes": archive_bytes,
        "archive_mib": round(archive_bytes / 1024 / 1024, 1) if archive_bytes is not None else None
    }
}

with open("$manifest", "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\\n")
PY

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" ${archive:+"$archive"}
log "source artifact ready: $artifact_dir"
