#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: nix-build-with-derived-mix-hash.sh EXPRESSION ATTR VERSION OUT_LINK HASH_FILE

Compatibility wrapper for the generalized fixed-output hash derivation helper.
The Nix expression must expose a mix-deps attribute, accept serviceVersion,
and read mix_deps_hash from SLIM_NIX_DERIVED_HASHES.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 5 ]] || { usage >&2; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
metadata_file="$(mktemp "${TMPDIR:-/tmp}/slim-mix-deps-metadata.XXXXXX")"
trap 'rm -f "$metadata_file"' EXIT

"$script_dir/nix-build-with-derived-hashes.sh" \
  nix-build "$1" "$2" "$3" "$4" "$metadata_file" \
  mix-deps:mix_deps_hash

python3 - "$metadata_file" "$5" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    metadata = json.load(fh)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(metadata["mix_deps_hash"] + "\n")
PY
