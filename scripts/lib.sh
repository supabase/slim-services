#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SERVICES=(
  edge-runtime
  studio
  pooler
  analytics
  storage
  postgrest
  realtime
  pgmeta
  auth
  postgres
)

log() {
  printf '[slim] %s\n' "$*"
}

fail() {
  printf '[slim] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

is_service() {
  local service="$1"
  local known
  for known in "${SERVICES[@]}"; do
    [[ "$known" == "$service" ]] && return 0
  done
  return 1
}

service_dir() {
  local service="$1"
  printf '%s/services/%s' "$ROOT_DIR" "$service"
}

recipe_file() {
  local service="$1"
  printf '%s/recipe.env' "$(service_dir "$service")"
}

load_recipe() {
  local service="$1"
  is_service "$service" || fail "unknown service: $service"
  local recipe
  recipe="$(recipe_file "$service")"
  [[ -f "$recipe" ]] || fail "recipe not found: $recipe"
  # shellcheck source=/dev/null
  source "$recipe"
}

host_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|amd64) printf 'amd64' ;;
    *) uname -m ;;
  esac
}

host_os() {
  case "$(uname -s)" in
    Darwin) printf 'darwin' ;;
    Linux) printf 'linux' ;;
    *) uname -s | tr '[:upper:]' '[:lower:]' ;;
  esac
}

normalize_os() {
  case "$1" in
    darwin|macos|macOS|Darwin) printf 'darwin' ;;
    linux|Linux) printf 'linux' ;;
    *) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
  esac
}

normalize_arch() {
  case "$1" in
    arm64|aarch64) printf 'arm64' ;;
    amd64|x86_64) printf 'amd64' ;;
    *) printf '%s' "$1" ;;
  esac
}

target_os() {
  normalize_os "${TARGET_OS:-${OS:-$(host_os)}}"
}

target_arch() {
  normalize_arch "${ARCH:-$(host_arch)}"
}

# linux-<arch> is the glibc target (the default, no suffix). Alternative
# libc flavors get a suffix: TARGET_LIBC=musl -> linux-<arch>-musl
# (reserved for future Alpine targets; no builds produce it yet).
artifact_platform_dir() {
  local os arch libc
  os="$(normalize_os "$1")"
  arch="$(normalize_arch "$2")"
  libc="${TARGET_LIBC:-glibc}"
  if [[ "$os" == "linux" && "$libc" != "glibc" ]]; then
    printf '%s-%s-%s' "$os" "$arch" "$libc"
  else
    printf '%s-%s' "$os" "$arch"
  fi
}

docker_platform() {
  local os="$1"
  local arch="$2"
  os="$(normalize_os "$os")"
  arch="$(normalize_arch "$arch")"
  [[ "$os" == "linux" ]] || fail "Docker images are only produced for linux targets, got: $os/$arch"
  printf 'linux/%s' "$arch"
}

nix_system_for() {
  local os="$1"
  local arch="$2"
  os="$(normalize_os "$os")"
  arch="$(normalize_arch "$arch")"

  case "$os/$arch" in
    linux/arm64) printf 'aarch64-linux' ;;
    linux/amd64) printf 'x86_64-linux' ;;
    darwin/arm64) printf 'aarch64-darwin' ;;
    darwin/amd64) fail "darwin/amd64 artifacts are out of scope for now" ;;
    *) fail "unsupported Nix system target: $os/$arch" ;;
  esac
}

artifact_rootfs_path() {
  local service="$1"
  local version="$2"
  local os="${3:-$(target_os)}"
  local arch="${4:-$(target_arch)}"
  printf '%s/artifacts/%s/%s/%s/rootfs' "$ROOT_DIR" "$service" "$version" "$(artifact_platform_dir "$os" "$arch")"
}

# Resolve SOURCE_REF to a commit sha inside a source checkout. CI initializes
# submodules with `--depth 1`, which fetches the pinned commit but not the tag
# the recipe names; fetch the missing tag shallowly before giving up.
resolve_source_ref() {
  local source_dir="$1"
  local ref="$2"
  local sha
  if sha="$(git -C "$source_dir" rev-parse --verify --quiet "$ref^{commit}")"; then
    printf '%s' "$sha"
    return 0
  fi
  # Callers capture stdout as the sha; keep the progress note on stderr.
  log "ref $ref not found in $source_dir; fetching tag from origin" >&2
  git -C "$source_dir" fetch --quiet --depth 1 origin \
    "refs/tags/$ref:refs/tags/$ref" 2>/dev/null || true
  git -C "$source_dir" rev-parse "$ref^{commit}"
}

host_matches_target() {
  local os="$1"
  local arch="$2"
  [[ "$(normalize_os "$os")" == "$(host_os)" && "$(normalize_arch "$arch")" == "$(host_arch)" ]]
}

archive_with_best_available_compressor() {
  local rootfs="$1"
  local archive_prefix="$2"
  local archive
  rm -f "${archive_prefix}.tar" "${archive_prefix}.tar.gz" "${archive_prefix}.tar.zst"

  local nix_cmd=""
  if command -v nix >/dev/null 2>&1; then
    nix_cmd="$(command -v nix)"
  elif [[ -x /nix/var/nix/profiles/default/bin/nix ]]; then
    nix_cmd="/nix/var/nix/profiles/default/bin/nix"
  elif [[ -x "$HOME/.nix-profile/bin/nix" ]]; then
    nix_cmd="$HOME/.nix-profile/bin/nix"
  fi

  if ! command -v zstd >/dev/null 2>&1 && [[ -n "$nix_cmd" ]] && [[ "${SLIM_USE_NIX_ZSTD:-1}" == "1" ]]; then
    local zstd_out
    while IFS= read -r zstd_out; do
      if [[ -n "$zstd_out" && -x "$zstd_out/bin/zstd" ]]; then
        PATH="$zstd_out/bin:$PATH"
        break
      fi
    done < <("$nix_cmd" --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths nixpkgs#zstd 2>/dev/null || true)
  fi

  if command -v zstd >/dev/null 2>&1; then
    archive="${archive_prefix}.tar.zst"
    tar -C "$rootfs" -cf - . | zstd -q -19 -o "$archive"
  elif command -v gzip >/dev/null 2>&1; then
    archive="${archive_prefix}.tar.gz"
    tar -C "$rootfs" -czf "$archive" .
  else
    archive="${archive_prefix}.tar"
    tar -C "$rootfs" -cf "$archive" .
  fi
  printf '%s\n' "$archive"
}

# Host-native artifact contract: recipes declare PORTABLE="true" (optionally
# per target, recipe.env is sourced with TARGET_OS/ARCH resolved) when the
# artifact is self-contained and relocatable — runnable straight from an
# extracted archive with no container. The manifest records the flag plus the
# libraries the artifact still expects from the host, so the CLI can verify
# host compatibility before running.
portable_flag() {
  printf '%s' "${PORTABLE:-false}"
}

portable_host_libs_json() {
  if [[ "$(portable_flag)" != "true" ]]; then
    printf '[]'
    return 0
  fi
  if [[ -n "${PORTABLE_HOST_LIBS_JSON:-}" ]]; then
    printf '%s' "$PORTABLE_HOST_LIBS_JSON"
    return 0
  fi
  case "$(target_os)" in
    darwin)
      # Every macOS install provides libSystem and the system frameworks.
      printf '["/usr/lib/libSystem.B.dylib","/System/Library/Frameworks"]'
      ;;
    linux)
      # The glibc family we deliberately resolve from the host/base image
      # (see should_exclude in services/edge-runtime/nix/edge-runtime.nix).
      printf '["ld-linux","libc","libdl","libpthread","libm","libresolv","librt"]'
      ;;
    *)
      printf '[]'
      ;;
  esac
}

relative_to_root() {
  local path="$1"
  python3 - "$ROOT_DIR" "$path" <<'PY'
import os
import sys
print(os.path.relpath(os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[1])))
PY
}
