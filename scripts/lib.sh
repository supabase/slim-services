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

archive_with_best_available_compressor() {
  local rootfs="$1"
  local archive_prefix="$2"
  local archive
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
