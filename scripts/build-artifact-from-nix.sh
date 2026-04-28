#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact-from-nix.sh SERVICE [VERSION]

Build SERVICE from a configured Nix flake/package and export selected runtime
paths into the common artifact layout.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd git
require_cmd tar
require_cmd python3

service="$1"
VERSION="${2:-${VERSION:-dev}}"
ARCH="${ARCH:-$(host_arch)}"
PLATFORM="${PLATFORM:-linux/$ARCH}"
case "$ARCH" in
  arm64) DEFAULT_NIX_SYSTEM="aarch64-linux" ;;
  amd64) DEFAULT_NIX_SYSTEM="x86_64-linux" ;;
  *) DEFAULT_NIX_SYSTEM="${ARCH}-linux" ;;
esac

load_recipe "$service"

SOURCE_DIR="${SOURCE_DIR:?recipe must define SOURCE_DIR}"
SOURCE_REF="${SOURCE_REF:?recipe must define SOURCE_REF}"
BASE_IMAGE="${BASE_IMAGE:?recipe must define BASE_IMAGE}"
ENTRYPOINT_JSON="${ENTRYPOINT_JSON:?recipe must define ENTRYPOINT_JSON}"
CMD_JSON="${CMD_JSON:-[]}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-${SOURCE_IMAGE:-}}"
NIX_FLAKE="${NIX_FLAKE:?recipe must define NIX_FLAKE}"
NIX_ATTR="${NIX_ATTR:?recipe must define NIX_ATTR}"
NIX_SYSTEM="${NIX_SYSTEM:-$DEFAULT_NIX_SYSTEM}"
NIX_RUNNER="${NIX_RUNNER:-auto}"
NIX_BUILD_MODE="${NIX_BUILD_MODE:-flake}"

source_abs="$ROOT_DIR/$SOURCE_DIR"
artifact_dir="$ROOT_DIR/artifacts/$service/$VERSION/linux-$ARCH"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"
out_link="$artifact_dir/nix-result"

[[ -d "$source_abs" ]] || fail "source submodule directory not found: $SOURCE_DIR"
[[ -f "$source_abs/.git" || -d "$source_abs/.git" ]] || fail "source directory is not a git checkout: $SOURCE_DIR"

expected_ref="$(git -C "$source_abs" rev-parse "$SOURCE_REF^{commit}" 2>/dev/null || git -C "$source_abs" rev-parse "$SOURCE_REF")"
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

case "$NIX_BUILD_MODE" in
  flake)
    if [[ "$NIX_ATTR" == packages.* || "$NIX_ATTR" == legacyPackages.* ]]; then
      nix_installable="${NIX_FLAKE}#${NIX_ATTR}"
    else
      nix_installable="${NIX_FLAKE}#packages.${NIX_SYSTEM}.${NIX_ATTR}"
    fi
    ;;
  nix-build)
    nix_installable="${NIX_FLAKE} -A ${NIX_ATTR}"
    ;;
  *)
    fail "unknown NIX_BUILD_MODE for $service: $NIX_BUILD_MODE"
    ;;
esac

if ! declare -p NIX_COPY_PATHS >/dev/null 2>&1; then
  fail "recipe must define NIX_COPY_PATHS for Nix backend"
fi

host_nix_system=""
if command -v nix >/dev/null 2>&1; then
  host_nix_system="$(nix eval --raw --impure --expr builtins.currentSystem 2>/dev/null || true)"
fi

if [[ "$NIX_RUNNER" == "auto" ]]; then
  if [[ -n "$host_nix_system" && "$host_nix_system" == "$NIX_SYSTEM" ]]; then
    resolved_nix_runner="local"
  else
    resolved_nix_runner="docker"
  fi
else
  resolved_nix_runner="$NIX_RUNNER"
fi

case "$resolved_nix_runner" in
  local)
    require_cmd nix
    log "building $service artifact with local Nix from $nix_installable"
    case "$NIX_BUILD_MODE" in
      flake)
        (
          cd "$ROOT_DIR"
          nix --extra-experimental-features "nix-command flakes" build \
            "$nix_installable" \
            --out-link "$out_link"
        )
        ;;
      nix-build)
        (
          cd "$ROOT_DIR"
          nix-build "$NIX_FLAKE" -A "$NIX_ATTR" --out-link "$out_link"
        )
        ;;
    esac

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

    chmod -R u+w "$rootfs"

    if [[ -f "$(service_dir "$service")/wrapper.sh" ]]; then
      wrapper_path="${WRAPPER_PATH:-/usr/local/bin/$service}"
      mkdir -p "$rootfs$(dirname "$wrapper_path")"
      cp "$(service_dir "$service")/wrapper.sh" "$rootfs$wrapper_path"
      chmod 0755 "$rootfs$wrapper_path"
    fi
    ;;
  docker)
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
      --build-arg "NIX_EXPRESSION=${NIX_EXPRESSION:-default.nix}" \
      "$ROOT_DIR"

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

"$ROOT_DIR/scripts/prune-runtime-tree.sh" "$rootfs"
archive="$(archive_with_best_available_compressor "$rootfs" "$artifact_dir/$service")"

rootfs_kib="$(du -sk "$rootfs" | awk '{print $1}')"
archive_bytes="$(wc -c < "$archive" | tr -d ' ')"

python3 - "$manifest" <<PY
import json
import os

manifest = {
    "service": "$service",
    "version": "$VERSION",
    "platform": "$PLATFORM",
    "arch": "$ARCH",
    "source_dir": "$SOURCE_DIR",
    "source_ref": "$SOURCE_REF",
    "source_commit": "$actual_ref",
    "upstream_image": "$UPSTREAM_IMAGE",
    "base_image": "$BASE_IMAGE",
    "entrypoint": json.loads("""$ENTRYPOINT_JSON"""),
    "cmd": json.loads("""$CMD_JSON"""),
    "build_backend": "nix",
    "nix_flake": "$NIX_FLAKE",
    "nix_attr": "$NIX_ATTR",
    "nix_build_mode": "$NIX_BUILD_MODE",
    "nix_system": "$NIX_SYSTEM",
    "nix_installable": "$nix_installable",
    "nix_runner": "$resolved_nix_runner",
    "host_nix_system": "$host_nix_system",
    "nix_copy_paths": ${NIX_COPY_PATHS_JSON:-[]},
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
    "archive": os.path.basename("$archive"),
    "size": {
        "rootfs_bytes": int($rootfs_kib) * 1024,
        "rootfs_mib": round((int($rootfs_kib) * 1024) / 1024 / 1024, 1),
        "archive_bytes": int($archive_bytes),
        "archive_mib": round(int($archive_bytes) / 1024 / 1024, 1)
    }
}

with open("$manifest", "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\\n")
PY

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" "$archive"
log "Nix artifact ready: $artifact_dir"
