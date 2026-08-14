#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/verify-external-release.sh SNAPSHOT VERSION

Verify the exact snapshot bytes and its sidecar, then validate the complete
snapshot/version policy offline.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

snapshot="$1"
version="$2"
sidecar="$snapshot.sha256"
[[ -f "$snapshot" && ! -L "$snapshot" ]] || { printf 'snapshot not found: %s\n' "$snapshot" >&2; exit 1; }
[[ -f "$sidecar" && ! -L "$sidecar" ]] || { printf 'snapshot digest sidecar not found: %s\n' "$sidecar" >&2; exit 1; }

expected="$(python3 - "$snapshot" <<'PY'
import hashlib
import pathlib
import sys

digest = hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()
print(digest)
PY
)"
printf '%s\n' "$expected" | cmp -s - "$sidecar" || {
  printf 'snapshot digest sidecar mismatch: %s\n' "$snapshot" >&2
  exit 1
}

release_tool=(python3 "$ROOT_DIR/scripts/upstream-release.py")
"${release_tool[@]}" release-tag "$snapshot" "$version" >/dev/null
"${release_tool[@]}" image "$snapshot" "$version" >/dev/null

record_kind="$(python3 - "$snapshot" "$version" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    policy = json.load(stream)
record = policy["versions"][sys.argv[2]]
print("source" if "source" in record else "assets")
PY
)"
if [[ "$record_kind" == "source" ]]; then
  "${release_tool[@]}" source "$snapshot" "$version" >/dev/null
else
  for target in darwin-arm64 linux-amd64 linux-arm64; do
    "${release_tool[@]}" asset "$snapshot" "$version" "$target" >/dev/null
  done
fi
printf 'verified external release snapshot %s (%s)\n' "$snapshot" "$version"
