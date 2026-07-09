#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/ci-build-service.sh SERVICE [VERSION]

Build and validate one service for one CI matrix target.

Environment:
  TARGET_OS=linux|darwin  defaults to host OS
  ARCH=arm64|amd64        defaults to host architecture
  IMAGE_TAG=...           optional Linux image tag
  DOCKER_PUSH=1           push Linux image instead of only loading locally
  DOCKER_LOAD=0|1         load Linux image locally, defaults to 1
  FORCE_ARTIFACT_SMOKE=1  also smoke the raw artifact on Linux targets
                          (normally skipped: the image smoke covers the
                          identical rootfs)

Steps:
  1. Build artifact rootfs for TARGET_OS/ARCH.
  2. Smoke the artifact.
  3. Create/update the distribution archive.
  4. For Linux only, build the final Docker image and smoke it.
  5. For Linux local images, record gzip-compressed docker-save size.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd python3

service="$1"
version="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
export TARGET_OS ARCH

platform_dir="$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
rootfs="$(artifact_rootfs_path "$service" "$version" "$TARGET_OS" "$ARCH")"
artifact_dir="$(dirname "$rootfs")"
manifest="$artifact_dir/manifest.json"

log "CI target: service=$service version=$version target=$TARGET_OS/$ARCH"

# Recipe-level policy knobs for the audit and the floor check below
# (GLIBC_FLOOR_MAX, MACOS_FLOOR_MAX, FLOOR_CHECK_CMD are plain recipe vars).
load_recipe "$service"
export GLIBC_FLOOR_MAX="${GLIBC_FLOOR_MAX:-}"
export MACOS_FLOOR_MAX="${MACOS_FLOOR_MAX:-}"

if [[ "$TARGET_OS" == "linux" && "${TARGET_LIBC:-glibc}" != "glibc" ]]; then
  fail "TARGET_LIBC=${TARGET_LIBC} is a reserved target flavor; no musl builds are implemented yet"
fi

merge_runtime_metrics() {
  local manifest_file="$1"
  local metrics_file="$2"
  [[ -f "$metrics_file" && -f "$manifest_file" ]] || return 0
  log "recording runtime metrics in manifest"
  python3 - "$manifest_file" "$metrics_file" <<'PY'
import json
import sys

manifest_path, metrics_path = sys.argv[1:]

with open(metrics_path, "r", encoding="utf-8") as fh:
    metrics = json.load(fh)

with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

data["runtime"] = metrics

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
}

# The distribution archive is created below; skip the duplicate archive the
# artifact builders would otherwise produce (zstd -19 over the full rootfs).
ARTIFACT_ARCHIVE_ON_BUILD=0 "$ROOT_DIR/scripts/build-artifact.sh" "$service" "$version"

[[ -d "$rootfs" ]] || fail "expected artifact rootfs not found: $rootfs"

# Portable artifacts must hold the host-native contract: no absolute build-
# machine paths, no unresolved libraries. The audit tooling is OS-specific
# (otool vs ldd), so it runs where the host OS matches the target.
artifact_portable="$(python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1])).get("portable") else "false")' "$manifest" 2>/dev/null || echo false)"
if [[ "$artifact_portable" == "true" && "$TARGET_OS" == "$(host_os)" ]]; then
  audit_mode="--linux"
  [[ "$TARGET_OS" == "darwin" ]] && audit_mode="--darwin"
  log "auditing portable artifact ($audit_mode)"
  "$ROOT_DIR/scripts/audit-portable-artifact.sh" "$audit_mode" "$rootfs"
fi

# Record the measured OS floor in the manifest so distribution consumers
# (the CLI) can pre-flight host compatibility with a clear error instead of
# a loader crash.
if [[ "$artifact_portable" == "true" && "$TARGET_OS" == "$(host_os)" ]]; then
  floor_mode="--linux"
  [[ "$TARGET_OS" == "darwin" ]] && floor_mode="--darwin"
  os_floor_json="$("$ROOT_DIR/scripts/os-floor.sh" "$floor_mode" "$rootfs")" \
    || fail "os-floor scan failed for $rootfs"
  log "recording os floor in manifest: $os_floor_json"
  python3 - "$manifest" "$os_floor_json" <<'PY'
import json
import sys

manifest_path, floor_raw = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["os_floor"] = json.loads(floor_raw)
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
fi

# Execution proof at the glibc floor: run the recipe's FLOOR_CHECK_CMD in a
# container whose glibc IS the floor. Linux-only (needs Docker) and only
# where the host matches the target (native rootfs).
if [[ "$artifact_portable" == "true" && "$TARGET_OS" == "linux" && "$(host_os)" == "linux" ]]; then
  "$ROOT_DIR/scripts/floor-check-linux.sh" "$service" "$rootfs"
fi

# On Linux the artifact smoke would build a temporary image from the exact
# rootfs the final image is built from and run the identical smoke — pure
# duplication. Smoke the artifact directly only where no image follows
# (darwin), or when explicitly requested.
if [[ "$TARGET_OS" != "linux" || "${FORCE_ARTIFACT_SMOKE:-0}" == "1" ]]; then
  log "smoking $service artifact for $platform_dir"
  runtime_metrics_file="$artifact_dir/runtime-metrics.json"
  rm -f "$runtime_metrics_file"
  SLIM_RUNTIME_METRICS_FILE="$runtime_metrics_file" \
    "$ROOT_DIR/scripts/smoke.sh" "$service" --artifact "$rootfs"

  # On darwin this is the only smoke, so these are the artifact's runtime
  # numbers; on Linux (FORCE_ARTIFACT_SMOKE) the image smoke below overwrites.
  if [[ "$TARGET_OS" != "linux" && ! -f "$runtime_metrics_file" ]]; then
    log "WARNING: smoke passed but recorded no runtime metrics — add a record_host_runtime_metrics call to services/$service/smoke.sh"
  fi
  merge_runtime_metrics "$manifest" "$runtime_metrics_file"
fi

archive_prefix="${ARTIFACT_ARCHIVE_PREFIX:-$artifact_dir/$service-$version-$platform_dir}"
log "creating distribution archive for $platform_dir"
"$ROOT_DIR/scripts/archive-artifact.sh" "$rootfs" "$archive_prefix"

# SHA256SUMS next to the archive so distribution consumers (the CLI) can
# verify downloads.
python3 - "$archive_prefix" <<'PY'
import glob
import hashlib
import os
import sys

prefix = sys.argv[1]
archives = sorted(glob.glob(prefix + ".tar*"))
if not archives:
    raise SystemExit(f"no archive found for prefix {prefix}")

out_path = os.path.join(os.path.dirname(prefix), "SHA256SUMS")
with open(out_path, "w", encoding="utf-8") as out:
    for archive in archives:
        digest = hashlib.sha256()
        with open(archive, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                digest.update(chunk)
        out.write(f"{digest.hexdigest()}  {os.path.basename(archive)}\n")
print(f"[slim] checksums written: {out_path}")
PY

if [[ "$TARGET_OS" == "linux" ]]; then
  image_tag="${IMAGE_TAG:-local/$service:slim-$version-linux-$ARCH}"

  log "building Linux Docker image: $image_tag"
  PLATFORM="$(docker_platform "$TARGET_OS" "$ARCH")" \
    "$ROOT_DIR/scripts/build-image-from-artifact.sh" "$service" "$rootfs" "$image_tag"

  if [[ "${DOCKER_PUSH:-0}" != "1" ]]; then
    log "smoking Linux Docker image: $image_tag"
    runtime_metrics_file="$artifact_dir/runtime-metrics.json"
    rm -f "$runtime_metrics_file"
    SLIM_RUNTIME_METRICS_FILE="$runtime_metrics_file" \
      "$ROOT_DIR/scripts/smoke.sh" "$service" --image "$image_tag"

    if [[ ! -f "$runtime_metrics_file" ]]; then
      log "WARNING: smoke passed but recorded no runtime metrics — add a record_runtime_metrics call to services/$service/smoke.sh"
    fi
    merge_runtime_metrics "$manifest" "$runtime_metrics_file"

    if command -v docker >/dev/null 2>&1; then
      log "measuring gzip-compressed Docker archive: $image_tag"
      # pigz produces the same -9 sizes as gzip but uses all cores; the
      # single-threaded fallback costs minutes on GiB-scale images.
      gzip_cmd="$(command -v pigz || command -v gzip)"
      gzip_bytes="$(
        docker save "$image_tag" | "$gzip_cmd" -9 | wc -c | tr -d ' '
      )"
      if [[ -f "$manifest" ]]; then
        python3 - "$manifest" "$gzip_bytes" <<'PY'
import json
import sys

manifest_path, gzip_bytes_raw = sys.argv[1:]
gzip_bytes = int(gzip_bytes_raw)

with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

data.setdefault("image", {})
data["image"]["gzip_bytes"] = gzip_bytes
data["image"]["gzip_mib"] = round(gzip_bytes / 1024 / 1024, 1)

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
      fi
      awk -v bytes="$gzip_bytes" 'BEGIN { printf "image_gzip_mib=%.1f\n", bytes / 1024 / 1024 }'
    fi
  else
    log "skipping local image smoke because DOCKER_PUSH=1"
  fi
elif [[ "$TARGET_OS" == "darwin" ]]; then
  log "Darwin target complete; Docker images are only produced for Linux targets"
else
  fail "unsupported CI target OS: $TARGET_OS"
fi

log "CI build complete: $artifact_dir"
