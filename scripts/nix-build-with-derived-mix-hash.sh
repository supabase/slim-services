#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-build-with-derived-mix-hash.sh EXPRESSION ATTR VERSION OUT_LINK HASH_FILE

Discover the fixed-output hash for a Mix dependency derivation, then build the
requested attribute with that exact hash. The Nix expression must expose a
mix-deps attribute and accept serviceVersion and mixDepsHash arguments.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 5 ]] || { usage >&2; exit 2; }

expression="$1"
attr="$2"
version="${3#v}"
out_link="$4"
hash_file="$5"

log_file="$(mktemp "${TMPDIR:-/tmp}/slim-mix-deps.XXXXXX")"
trap 'rm -f "$log_file"' EXIT

set +e
nix-build "$expression" -A mix-deps \
  --argstr serviceVersion "$version" \
  --no-out-link 2>&1 | tee "$log_file"
build_status="${PIPESTATUS[0]}"
set -e

if [[ "$build_status" -eq 0 ]]; then
  printf 'Mix dependency hash discovery unexpectedly matched the fake hash\n' >&2
  exit 1
fi

mix_deps_hash="$(
  sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+\/=]+).*/\1/p' "$log_file" \
    | tail -n 1
)"
[[ -n "$mix_deps_hash" ]] || {
  printf 'Nix failed without reporting a Mix dependency hash\n' >&2
  exit "$build_status"
}

printf '[slim] resolved Mix dependency hash: %s\n' "$mix_deps_hash"
printf '%s\n' "$mix_deps_hash" > "$hash_file"

nix-build "$expression" -A "$attr" \
  --argstr serviceVersion "$version" \
  --argstr mixDepsHash "$mix_deps_hash" \
  --out-link "$out_link"
