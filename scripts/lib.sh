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

artifact_platform_dir() {
  local os="$1"
  local arch="$2"
  printf '%s-%s' "$(normalize_os "$os")" "$(normalize_arch "$arch")"
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

relative_to_root() {
  local path="$1"
  python3 - "$ROOT_DIR" "$path" <<'PY'
import os
import sys
print(os.path.relpath(os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[1])))
PY
}
