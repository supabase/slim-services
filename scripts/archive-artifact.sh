#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/archive-artifact.sh ARTIFACT_ROOTFS [ARCHIVE_PREFIX]

Compress an existing artifact rootfs as a distribution artifact. When
ARCHIVE_PREFIX is omitted, the script uses the service name from the sibling
manifest.json, falling back to "artifact".
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd python3

rootfs="$1"
[[ -d "$rootfs" ]] || fail "artifact rootfs not found: $rootfs"

artifact_dir="$(dirname "$rootfs")"
manifest="$artifact_dir/manifest.json"

if [[ $# -eq 2 ]]; then
  archive_prefix="$2"
else
  service_name="artifact"
  if [[ -f "$manifest" ]]; then
    service_name="$(python3 - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    print(json.load(fh).get("service") or "artifact")
PY
)"
  fi
  archive_prefix="$artifact_dir/$service_name"
fi

archive="$(archive_with_best_available_compressor "$rootfs" "$archive_prefix")"
archive_bytes="$(wc -c < "$archive" | tr -d ' ')"

if [[ -f "$manifest" ]]; then
  python3 - "$manifest" "$archive" "$archive_bytes" <<'PY'
import json
import os
import sys

manifest_path, archive_path, archive_bytes_raw = sys.argv[1:]
archive_bytes = int(archive_bytes_raw)

with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

data["archive"] = os.path.basename(archive_path)
data["archive_on_build"] = False
data.setdefault("size", {})
data["size"]["archive_bytes"] = archive_bytes
data["size"]["archive_mib"] = round(archive_bytes / 1024 / 1024, 1)

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
fi

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" "$archive"
log "archive ready: $archive"
