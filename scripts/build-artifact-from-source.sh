#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact-from-source.sh SERVICE [VERSION]

Build SERVICE from its pinned sources/SERVICE git checkout using
services/SERVICE/build-host.sh, then write the common artifact layout:

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

SOURCE_DIR="${SOURCE_DIR:?recipe must define SOURCE_DIR}"
SOURCE_REF="${SOURCE_REF:?recipe must define SOURCE_REF}"
BASE_IMAGE="${BASE_IMAGE:?recipe must define BASE_IMAGE}"
ENTRYPOINT_JSON="${ENTRYPOINT_JSON:?recipe must define ENTRYPOINT_JSON}"
CMD_JSON="${CMD_JSON:-[]}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-${SOURCE_IMAGE:-}}"

artifact_dir="$ROOT_DIR/artifacts/$service/$VERSION/$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"
sbom="$artifact_dir/$service-$VERSION-$(artifact_platform_dir "$TARGET_OS" "$ARCH").sbom.spdx.json"

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

host_build="$ROOT_DIR/services/$service/build-host.sh"
[[ -x "$host_build" ]] || fail "$service has no host build script: $host_build"

# A previous mode-preserving extraction may have left read-only directories
# (Nix store trees); make them deletable before clearing.
if [[ -d "$rootfs" ]]; then
  chmod -R u+w "$rootfs" 2>/dev/null || true
fi
rm -rf "$rootfs"
mkdir -p "$rootfs" "$artifact_dir"

log "building $service artifact from $SOURCE_DIR@$SOURCE_REF with host toolchain for $TARGET_OS/$ARCH"
SERVICE="$service" \
  VERSION="$VERSION" \
  TARGET_OS="$TARGET_OS" \
  ARCH="$ARCH" \
  SOURCE_DIR="$source_abs" \
  ROOTFS="$rootfs" \
  ROOT_DIR="$ROOT_DIR" \
  "$host_build"

"$ROOT_DIR/scripts/prune-runtime-tree.sh" "$rootfs"
if [[ "$service" == "studio" ]]; then
  # Studio's host build assembles a Next/TanStack runtime tree; validate the
  # post-prune tree as the exact input that will be archived below.
  "$ROOT_DIR/services/studio/validate-artifact.sh" "$rootfs"
fi
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
    "build_mode": "host-source",
    "artifact_dockerfile": None,
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

if [[ "$service" == "studio" ]]; then
  # Re-check the published command paths against the generated manifest after
  # the manifest itself has been written, before reporting a successful build.
  "$ROOT_DIR/services/studio/validate-artifact.sh" "$rootfs" "$manifest"
fi

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" ${archive:+"$archive"}
log "source artifact ready: $artifact_dir"
