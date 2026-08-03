#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-build-with-derived-hashes.sh MODE INSTALLABLE ATTR VERSION OUT_LINK HASH_FILE SPEC...

Discover one or more Nix fixed-output hashes, then perform the verified final
build. MODE is "nix-build" or "flake". For nix-build, INSTALLABLE is the Nix
expression and ATTR is the final attribute. For flake, INSTALLABLE is the full
flake installable and ATTR must be "-".

Each SPEC is PROBE_ATTR:JSON_KEY. The Nix expression reads the accumulated
hashes from SLIM_NIX_DERIVED_HASHES and must use lib.fakeHash for keys that are
not present. Probe attributes must resolve to exactly one fixed-output
derivation. The resolved JSON object is written to HASH_FILE.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 7 ]] || { usage >&2; exit 2; }

mode="$1"
installable="$2"
attr="$3"
version="${4#v}"
out_link="$5"
hash_file="$6"
shift 6
specs=("$@")

case "$mode" in
  nix-build|flake) ;;
  *) printf 'unsupported Nix build mode: %s\n' "$mode" >&2; exit 2 ;;
esac
if [[ "$mode" == "nix-build" && "$attr" == "-" ]]; then
  printf 'nix-build mode requires a final attribute\n' >&2
  exit 2
fi
if [[ "$mode" == "flake" && "$attr" != "-" ]]; then
  printf 'flake mode requires ATTR to be -\n' >&2
  exit 2
fi

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-nix-hashes.XXXXXX")"
trap 'rm -rf "$log_dir"' EXIT

hash_json="{}"

add_hash() {
  local key="$1"
  local value="$2"
  if [[ "$hash_json" == "{}" ]]; then
    hash_json="{\"$key\":\"$value\"}"
  else
    hash_json="${hash_json%?},\"$key\":\"$value\"}"
  fi
}

run_probe() {
  local probe_attr="$1"
  if [[ "$mode" == "nix-build" ]]; then
    SLIM_NIX_SERVICE_VERSION="$version" \
    SLIM_NIX_DERIVED_HASHES="$hash_json" \
      nix-build "$installable" -A "$probe_attr" \
        --argstr serviceVersion "$version" \
        --no-out-link
  else
    SLIM_NIX_SERVICE_VERSION="$version" \
    SLIM_NIX_DERIVED_HASHES="$hash_json" \
      nix --extra-experimental-features "nix-command flakes" \
        --option eval-cache false \
        build --impure --accept-flake-config \
        "${installable}.${probe_attr}" --no-link
  fi
}

for spec in "${specs[@]}"; do
  [[ "$spec" == *:* ]] || {
    printf 'invalid derived hash spec (expected PROBE_ATTR:JSON_KEY): %s\n' "$spec" >&2
    exit 2
  }
  probe_attr="${spec%%:*}"
  hash_key="${spec#*:}"
  [[ "$probe_attr" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'invalid probe attribute: %s\n' "$probe_attr" >&2
    exit 2
  }
  [[ "$hash_key" =~ ^[a-z0-9_]+$ ]] || {
    printf 'invalid derived hash key: %s\n' "$hash_key" >&2
    exit 2
  }

  log_file="$log_dir/$hash_key.log"
  set +e
  run_probe "$probe_attr" 2>&1 | tee "$log_file"
  probe_status="${PIPESTATUS[0]}"
  set -e

  if [[ "$probe_status" -eq 0 ]]; then
    printf 'hash discovery for %s unexpectedly matched lib.fakeHash\n' \
      "$probe_attr" >&2
    exit 1
  fi

  resolved_hash="$(
    sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+\/=]+).*/\1/p' "$log_file" \
      | tail -n 1
  )"
  [[ -n "$resolved_hash" ]] || {
    printf 'Nix failed without reporting a hash for %s\n' "$probe_attr" >&2
    exit "$probe_status"
  }

  printf '[slim] resolved %s: %s\n' "$hash_key" "$resolved_hash"
  add_hash "$hash_key" "$resolved_hash"
done

printf '%s\n' "$hash_json" > "$hash_file"

if [[ "$mode" == "nix-build" ]]; then
  SLIM_NIX_SERVICE_VERSION="$version" \
  SLIM_NIX_DERIVED_HASHES="$hash_json" \
    nix-build "$installable" -A "$attr" \
      --argstr serviceVersion "$version" \
      --out-link "$out_link"
else
  SLIM_NIX_SERVICE_VERSION="$version" \
  SLIM_NIX_DERIVED_HASHES="$hash_json" \
    nix --extra-experimental-features "nix-command flakes" \
      --option eval-cache false \
      build --impure --accept-flake-config \
      "$installable" --out-link "$out_link"
fi
