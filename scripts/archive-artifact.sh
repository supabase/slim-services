#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nix.sh
source "$ROOT_DIR/scripts/nix.sh"

usage() {
  cat <<'EOF'
Usage: scripts/archive-artifact.sh ARTIFACT_ROOTFS [ARCHIVE_PREFIX]

Create a deterministic zstd distribution archive with the pinned Nix archive
derivation. When ARCHIVE_PREFIX is omitted, the service name comes from the
sibling manifest.json and the archive is written beside the rootfs.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd python3
require_cmd nix

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
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream).get("service") or "artifact")
PY
)"
  fi
  archive_prefix="$artifact_dir/$service_name"
fi

archive_prefix="${archive_prefix%.tar.zst}"
archive_prefix="${archive_prefix%.tar.gz}"
archive_prefix="${archive_prefix%.tar}"
archive="${archive_prefix}.tar.zst"
rm -f "$archive_prefix.tar" "$archive_prefix.tar.gz" "$archive"

release_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-archive-release.XXXXXX")"
cleanup_release() { rm -rf "$release_dir"; }
trap cleanup_release EXIT
mkdir -p "$release_dir"
cp -a "$rootfs" "$release_dir/rootfs"
python3 - "$release_dir/release.json" "$manifest" "$(basename "$archive_prefix")" <<'PY'
import json
import os
import sys

output, manifest_path, archive_prefix = sys.argv[1:]
metadata = {}
if os.path.isfile(manifest_path):
    with open(manifest_path, encoding="utf-8") as stream:
        metadata = json.load(stream)
metadata["archive_prefix"] = archive_prefix
with open(output, "w", encoding="utf-8") as stream:
    json.dump(metadata, stream, indent=2)
    stream.write("\n")
PY

log "archiving $rootfs with pinned Nix"
# Compression is target-independent. Build this small derivation on the host
# system so a Linux artifact can be archived on a macOS release runner too.
nix_archive="$(nix_release build "$release_dir" "packages.$(nix_system_for "$(host_os)" "$(host_arch)").archive" --no-link --print-out-paths)"
[[ -f "$nix_archive" ]] || fail "Nix archive output is not a file: $nix_archive"
cp "$nix_archive" "$archive"

archive_bytes="$(wc -c < "$archive" | tr -d ' ')"
if [[ -f "$manifest" ]]; then
  python3 - "$manifest" "$archive" "$archive_bytes" <<'PY'
import json
import os
import sys

manifest_path, archive_path, archive_bytes_raw = sys.argv[1:]
archive_bytes = int(archive_bytes_raw)
with open(manifest_path, encoding="utf-8") as stream:
    data = json.load(stream)
data["archive"] = os.path.basename(archive_path)
data["archive_on_build"] = False
data.setdefault("size", {})
data["size"].update({
    "archive_bytes": archive_bytes,
    "archive_mib": round(archive_bytes / 1024 / 1024, 1),
})
with open(manifest_path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
PY
fi

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" "$archive"
log "archive ready: $archive"
