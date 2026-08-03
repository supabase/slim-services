#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact-from-nix.sh SERVICE [VERSION]

Build SERVICE from a configured Nix flake/package and export runtime files
into the common artifact layout.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd git
require_cmd tar
require_cmd python3
PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

service="$1"
VERSION="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
if [[ -n "${PLATFORM:-}" ]]; then
  PLATFORM="$PLATFORM"
elif [[ "$TARGET_OS" == "linux" ]]; then
  PLATFORM="$(docker_platform "$TARGET_OS" "$ARCH")"
else
  PLATFORM="$TARGET_OS/$ARCH"
fi
DEFAULT_NIX_SYSTEM="$(nix_system_for "$TARGET_OS" "$ARCH")"

load_recipe "$service"

SOURCE_DIR="${SOURCE_DIR:?recipe must define SOURCE_DIR}"
SOURCE_REF="${SOURCE_REF:?recipe must define SOURCE_REF}"
BASE_IMAGE="${BASE_IMAGE:?recipe must define BASE_IMAGE}"
ENTRYPOINT_JSON="${ENTRYPOINT_JSON:?recipe must define ENTRYPOINT_JSON}"
CMD_JSON="${CMD_JSON:-[]}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-${SOURCE_IMAGE:-}}"
NIX_FLAKE="${NIX_FLAKE:?recipe must define NIX_FLAKE}"
NIX_ATTR="${NIX_ATTR:?recipe must define NIX_ATTR}"
if [[ -n "${NIX_SYSTEM:-}" && "$NIX_SYSTEM" != "$DEFAULT_NIX_SYSTEM" ]]; then
  fail "NIX_SYSTEM=$NIX_SYSTEM does not match target $TARGET_OS/$ARCH ($DEFAULT_NIX_SYSTEM)"
fi
NIX_SYSTEM="$DEFAULT_NIX_SYSTEM"
NIX_RUNNER="${NIX_RUNNER:-auto}"
NIX_BUILD_MODE="${NIX_BUILD_MODE:-flake}"
NIX_BUILD_COMMAND_TEMPLATE="${NIX_BUILD_COMMAND_TEMPLATE:-}"
NIX_PACKAGE_OVERLAY="${NIX_PACKAGE_OVERLAY:-}"
NIX_PACKAGE_OVERLAY_DEST="${NIX_PACKAGE_OVERLAY_DEST:-}"
NIX_DERIVE_MIX_DEPS_HASH="${NIX_DERIVE_MIX_DEPS_HASH:-false}"

source_abs="$ROOT_DIR/$SOURCE_DIR"
artifact_dir="$ROOT_DIR/artifacts/$service/$VERSION/$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"
out_link="$artifact_dir/nix-result"
mix_deps_hash_file="$artifact_dir/mix-deps-hash"
mix_deps_hash=""

[[ -d "$source_abs" ]] || fail "source submodule directory not found: $SOURCE_DIR"
[[ -f "$source_abs/.git" || -d "$source_abs/.git" ]] || fail "source directory is not a git checkout: $SOURCE_DIR"

expected_ref="$(resolve_source_ref "$source_abs" "$SOURCE_REF")"
actual_ref="$(git -C "$source_abs" rev-parse HEAD)"
if [[ "$actual_ref" != "$expected_ref" ]]; then
  fail "$SOURCE_DIR is at $actual_ref, expected $SOURCE_REF ($expected_ref). Run: git submodule update --init --recursive"
fi

if [[ -n "$(git -C "$source_abs" status --short)" ]]; then
  fail "$SOURCE_DIR has local modifications; Nix artifact builds require clean submodules"
fi

rm -rf "$rootfs"
mkdir -p "$rootfs" "$artifact_dir"
rm -f "$out_link"
rm -f "$mix_deps_hash_file"

if ! declare -p NIX_COPY_PATHS >/dev/null 2>&1 && [[ "${NIX_OUTPUT_KIND:-copy-paths}" != "rootfs" ]]; then
  fail "recipe must define NIX_COPY_PATHS for Nix backend"
fi

host_nix_system=""
if command -v nix >/dev/null 2>&1; then
  host_nix_system="$(nix eval --raw --impure --expr builtins.currentSystem 2>/dev/null || true)"
fi

if [[ "$NIX_RUNNER" == "auto" ]]; then
  if [[ "$TARGET_OS" != "linux" ]]; then
    resolved_nix_runner="local"
  elif [[ -n "$host_nix_system" && "$host_nix_system" == "$NIX_SYSTEM" ]]; then
    resolved_nix_runner="local"
  else
    resolved_nix_runner="docker"
  fi
else
  resolved_nix_runner="$NIX_RUNNER"
fi

if [[ "$resolved_nix_runner" == "local" && -n "$host_nix_system" && "$host_nix_system" != "$NIX_SYSTEM" ]]; then
  fail "local Nix runner is $host_nix_system, but target is $NIX_SYSTEM. Use a native runner for $TARGET_OS/$ARCH."
fi

nix_flake_for_build="$NIX_FLAKE"
build_dir=""
if [[ "$resolved_nix_runner" == "local" && -n "$NIX_PACKAGE_OVERLAY" ]]; then
  overlay_abs="$ROOT_DIR/$NIX_PACKAGE_OVERLAY"
  [[ -e "$overlay_abs" ]] || fail "Nix package overlay not found: $NIX_PACKAGE_OVERLAY"
  NIX_PACKAGE_OVERLAY_DEST="${NIX_PACKAGE_OVERLAY_DEST:-nix/$(basename "$NIX_PACKAGE_OVERLAY")}"
  build_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-images-$service-$TARGET_OS-$ARCH.XXXXXX")"
  build_dir="$(cd "$build_dir" && pwd -P)"
  build_src="$build_dir/src"
  mkdir -p "$build_src"

  log "exporting $SOURCE_DIR@$actual_ref to temporary Nix build tree"
  git -C "$source_abs" archive HEAD | tar -C "$build_src" -xf -

  log "applying Nix package overlay $NIX_PACKAGE_OVERLAY -> $NIX_PACKAGE_OVERLAY_DEST"
  if [[ -d "$overlay_abs" ]]; then
    mkdir -p "$build_src/$NIX_PACKAGE_OVERLAY_DEST"
    cp -R "$overlay_abs/." "$build_src/$NIX_PACKAGE_OVERLAY_DEST/"
  else
    mkdir -p "$(dirname "$build_src/$NIX_PACKAGE_OVERLAY_DEST")"
    cp "$overlay_abs" "$build_src/$NIX_PACKAGE_OVERLAY_DEST"
  fi
  nix_flake_for_build="$build_src"
fi

case "$NIX_BUILD_MODE" in
  flake)
    if [[ "$NIX_ATTR" == packages.* || "$NIX_ATTR" == legacyPackages.* ]]; then
      nix_installable="${nix_flake_for_build}#${NIX_ATTR}"
    else
      nix_installable="${nix_flake_for_build}#packages.${NIX_SYSTEM}.${NIX_ATTR}"
    fi
    ;;
  nix-build)
    # NIX_EXPRESSION points at the .nix file or directory (relative to the
    # build tree) holding the attribute set, e.g. "nix" for repo-owned
    # services/<service>/nix/default.nix overlays.
    nix_installable="${nix_flake_for_build}/${NIX_EXPRESSION:-.} -A ${NIX_ATTR}"
    ;;
  *)
    fail "unknown NIX_BUILD_MODE for $service: $NIX_BUILD_MODE"
    ;;
esac

case "$resolved_nix_runner" in
  local)
    require_cmd nix
    log "building $service artifact with local Nix from $nix_installable"
    case "$NIX_BUILD_MODE" in
      flake)
        (
          cd "$ROOT_DIR"
          if [[ -n "$NIX_BUILD_COMMAND_TEMPLATE" ]]; then
            export NIX_INSTALLABLE="$nix_installable"
            export NIX_SYSTEM="$NIX_SYSTEM"
            export NIX_OUT_LINK="$out_link"
            log "using explicit Nix build command template"
            bash -lc "$NIX_BUILD_COMMAND_TEMPLATE"
          else
            nix --extra-experimental-features "nix-command flakes" build \
              "$nix_installable" \
              --out-link "$out_link"
          fi
        )
        ;;
      nix-build)
        (
          cd "$ROOT_DIR"
          if [[ "$NIX_DERIVE_MIX_DEPS_HASH" == "true" ]]; then
            "$ROOT_DIR/scripts/nix-build-with-derived-mix-hash.sh" \
              "$nix_flake_for_build/${NIX_EXPRESSION:-.}" \
              "$NIX_ATTR" "$VERSION" "$out_link" "$mix_deps_hash_file"
          else
            nix-build "$nix_flake_for_build/${NIX_EXPRESSION:-.}" \
              -A "$NIX_ATTR" --out-link "$out_link"
          fi
        )
        ;;
    esac

    if [[ "${NIX_OUTPUT_KIND:-copy-paths}" == "rootfs" ]]; then
      log "copying full Nix rootfs output from $out_link"
      tar -C "$out_link" -cf - . | tar -C "$rootfs" -xf -
    else
      copy_nix_path() {
        local spec="$1"
        local src_path dst_path src dst
        if [[ "$spec" == *:* ]]; then
          src_path="${spec%%:*}"
          dst_path="${spec#*:}"
        else
          src_path="$spec"
          dst_path="$spec"
        fi
        src="$out_link${src_path}"
        dst="$rootfs${dst_path}"
        [[ -e "$src" ]] || fail "Nix output path not found: $src_path in $out_link"
        mkdir -p "$(dirname "$dst")"
        cp -RL "$src" "$dst"
      }

      for path in "${NIX_COPY_PATHS[@]}"; do
        copy_nix_path "$path"
      done
    fi

    chmod -R u+w "$rootfs"

    if [[ -f "$(service_dir "$service")/wrapper.sh" ]]; then
      wrapper_path="${WRAPPER_PATH:-/usr/local/bin/$service}"
      mkdir -p "$rootfs$(dirname "$wrapper_path")"
      cp "$(service_dir "$service")/wrapper.sh" "$rootfs$wrapper_path"
      chmod 0755 "$rootfs$wrapper_path"
    fi
    ;;
  docker)
    [[ "$TARGET_OS" == "linux" ]] || fail "Docker-hosted Nix builds are only supported for linux targets"
    require_cmd docker
    dockerfile="$ROOT_DIR/services/$service/Dockerfile.artifact"
    [[ -f "$dockerfile" ]] || fail "Nix Docker runner requires $dockerfile"
    docker_builder="${DOCKER_BUILDER:-$(docker context show 2>/dev/null || echo default)}"
    log "building $service artifact with Docker-hosted Nix from $SOURCE_DIR for $PLATFORM using builder $docker_builder"
    docker buildx build \
      --builder "$docker_builder" \
      --platform "$PLATFORM" \
      --target artifact \
      --output "type=local,dest=$rootfs" \
      -f "$dockerfile" \
      --build-arg "SOURCE_DIR=$SOURCE_DIR" \
      --build-arg "SERVICE_VERSION=$VERSION" \
      --build-arg "NIX_ATTR=$NIX_ATTR" \
      --build-arg "NIX_SYSTEM=$NIX_SYSTEM" \
      --build-arg "NIX_EXPRESSION=${NIX_EXPRESSION:-default.nix}" \
      "$ROOT_DIR"

    if [[ -f "$rootfs/.slim-mix-deps-hash" ]]; then
      mv "$rootfs/.slim-mix-deps-hash" "$mix_deps_hash_file"
    fi

    chmod -R u+w "$rootfs"

    if [[ -f "$(service_dir "$service")/wrapper.sh" ]]; then
      wrapper_path="${WRAPPER_PATH:-/usr/local/bin/$service}"
      mkdir -p "$rootfs$(dirname "$wrapper_path")"
      cp "$(service_dir "$service")/wrapper.sh" "$rootfs$wrapper_path"
      chmod 0755 "$rootfs$wrapper_path"
    fi
    ;;
  *)
    fail "unknown NIX_RUNNER for $service: $resolved_nix_runner"
    ;;
esac

if [[ "$NIX_DERIVE_MIX_DEPS_HASH" == "true" ]]; then
  [[ -s "$mix_deps_hash_file" ]] || fail "Mix dependency hash was not recorded"
  mix_deps_hash="$(tr -d '\n' < "$mix_deps_hash_file")"
  rm -f "$mix_deps_hash_file"
fi

# The Nix sandbox signs with the sigtool shim, which produces invalid
# signatures on some special Mach-O layouts (e.g. reexport stubs like
# libiconv.dylib) — macOS SIGKILLs anything that loads such a file. Repair
# with the host's real codesign; the darwin audit fails the build if any
# invalid signature survives.
if [[ "$TARGET_OS" == "darwin" ]]; then
  log "verifying/repairing Mach-O code signatures with host codesign"
  find "$rootfs" -type f | while IFS= read -r macho; do
    file "$macho" 2>/dev/null | grep -q 'Mach-O' || continue
    if ! /usr/bin/codesign --verify "$macho" >/dev/null 2>&1; then
      chmod u+w "$macho" 2>/dev/null || true
      /usr/bin/codesign --force --sign - "$macho" 2>/dev/null \
        && log "re-signed: ${macho#"$rootfs"/}"
    fi
  done
fi

"$ROOT_DIR/scripts/prune-runtime-tree.sh" "$rootfs"
archive=""
if [[ "${ARTIFACT_ARCHIVE_ON_BUILD:-1}" == "1" ]]; then
  archive="$(archive_with_best_available_compressor "$rootfs" "$artifact_dir/$service")"
else
  rm -f "$artifact_dir/$service.tar" "$artifact_dir/$service.tar.gz" "$artifact_dir/$service.tar.zst"
fi

rootfs_kib="$(du -sk "$rootfs" | awk '{print $1}')"
archive_bytes=""
if [[ -n "$archive" ]]; then
  archive_bytes="$(wc -c < "$archive" | tr -d ' ')"
fi

portable="$(portable_flag)"
assumed_host_libs_json="$(portable_host_libs_json)"

# The build command template may contain quotes; pass it via the environment
# rather than interpolating it into the python source.
MIX_DEPS_HASH_ENV="$mix_deps_hash" \
NIX_BUILD_COMMAND_TEMPLATE_ENV="$NIX_BUILD_COMMAND_TEMPLATE" \
python3 - "$manifest" "$archive" "$archive_bytes" <<PY
import json
import os
import sys

_, manifest_path, archive_path, archive_bytes_raw = sys.argv
archive_name = os.path.basename(archive_path) if archive_path else None
archive_bytes = int(archive_bytes_raw) if archive_bytes_raw else None

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
    "base_image": "$BASE_IMAGE",
    "entrypoint": json.loads("""$ENTRYPOINT_JSON"""),
    "cmd": json.loads("""$CMD_JSON"""),
    "build_backend": "nix",
    "nix_flake": "$NIX_FLAKE",
    "nix_flake_for_build": "$nix_flake_for_build",
    "nix_attr": "$NIX_ATTR",
    "nix_build_mode": "$NIX_BUILD_MODE",
    "nix_build_command_template": os.environ.get("NIX_BUILD_COMMAND_TEMPLATE_ENV", ""),
    "nix_output_kind": "${NIX_OUTPUT_KIND:-copy-paths}",
    "nix_system": "$NIX_SYSTEM",
    "nix_installable": "$nix_installable",
    "nix_runner": "$resolved_nix_runner",
    "host_nix_system": "$host_nix_system",
    "nix_package_overlay": "$NIX_PACKAGE_OVERLAY",
    "nix_package_overlay_dest": "$NIX_PACKAGE_OVERLAY_DEST",
    "mix_deps_hash": os.environ.get("MIX_DEPS_HASH_ENV") or None,
    "nix_copy_paths": ${NIX_COPY_PATHS_JSON:-[]},
    "portable": "$portable" == "true",
    "assumed_host_libs": json.loads("""$assumed_host_libs_json"""),
    "archive_on_build": "${ARTIFACT_ARCHIVE_ON_BUILD:-1}" == "1",
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
    "archive": archive_name,
    "size": {
        "rootfs_bytes": int($rootfs_kib) * 1024,
        "rootfs_mib": round((int($rootfs_kib) * 1024) / 1024 / 1024, 1),
        "archive_bytes": archive_bytes,
        "archive_mib": round(archive_bytes / 1024 / 1024, 1) if archive_bytes is not None else None
    }
}

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\\n")
PY

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" "$archive"
log "Nix artifact ready: $artifact_dir"
