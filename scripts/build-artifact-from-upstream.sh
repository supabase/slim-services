#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact-from-upstream.sh SERVICE [VERSION]

Download a pinned upstream release archive, verify it before extraction, and
normalize its exact allowlisted members into the common artifact layout.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd curl
require_cmd python3
require_cmd tar
require_cmd zstd

service="$1"
VERSION="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
if [[ "$TARGET_OS" == "linux" ]]; then
  PLATFORM="${PLATFORM:-$(docker_platform "$TARGET_OS" "$ARCH")}"
else
  PLATFORM="${PLATFORM:-$TARGET_OS/$ARCH}"
fi

load_recipe "$service"

UPSTREAM_ASSETS_FILE="${UPSTREAM_ASSETS_FILE:?recipe must define UPSTREAM_ASSETS_FILE}"
UPSTREAM_ARCHIVE_MAPPING_JSON="${UPSTREAM_ARCHIVE_MAPPING_JSON:?recipe must define UPSTREAM_ARCHIVE_MAPPING_JSON}"
UPSTREAM_ARCHIVE_EXECUTABLES_JSON="${UPSTREAM_ARCHIVE_EXECUTABLES_JSON:?recipe must define UPSTREAM_ARCHIVE_EXECUTABLES_JSON}"
ENTRYPOINT_JSON="${ENTRYPOINT_JSON:?recipe must define ENTRYPOINT_JSON}"
CMD_JSON="${CMD_JSON:-[]}"

policy_file="$UPSTREAM_ASSETS_FILE"
[[ "$policy_file" = /* ]] || policy_file="$ROOT_DIR/$policy_file"
[[ -f "$policy_file" ]] || fail "upstream asset policy not found: $policy_file"

target="$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
if ! asset_json="$(python3 "$ROOT_DIR/scripts/upstream-release.py" asset \
  "$policy_file" "$VERSION" "$target")"; then
  fail "could not resolve upstream archive policy for $service $VERSION $target"
fi

asset_name="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["name"])' <<< "$asset_json")"
asset_url="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["url"])' <<< "$asset_json")"
expected_sha256="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["sha256"])' <<< "$asset_json")"
repository="$(python3 - "$policy_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["repository"])
PY
)"

download="$(mktemp "${TMPDIR:-/tmp}/slim-${service}-upstream.XXXXXX")"
cleanup_download() {
  rm -f "$download"
}
trap cleanup_download EXIT

log "downloading verified upstream archive $asset_name"
curl -fL "$asset_url" -o "$download"
actual_sha256="$(python3 - "$download" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"
[[ "$actual_sha256" == "$expected_sha256" ]] || fail \
  "upstream archive sha256 mismatch: expected $expected_sha256, got $actual_sha256"

artifact_dir="$ROOT_DIR/artifacts/$service/$VERSION/$target"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"
sbom="$artifact_dir/$service-$VERSION-$target.sbom.spdx.json"
archive=""

if [[ -d "$rootfs" ]]; then
  chmod -R u+w "$rootfs" 2>/dev/null || true
fi
rm -rf "$rootfs"
mkdir -p "$rootfs" "$artifact_dir"

log "normalizing $asset_name into $rootfs"
installed_members="$(python3 "$ROOT_DIR/scripts/extract-upstream-archive.py" \
  "$download" "$rootfs" "$UPSTREAM_ARCHIVE_MAPPING_JSON" \
  "$UPSTREAM_ARCHIVE_EXECUTABLES_JSON")"

"$ROOT_DIR/scripts/generate-artifact-sbom.sh" \
  "$rootfs" "$sbom" "$service" "$VERSION" "$target"

rootfs_kib="$(du -sk "$rootfs" | awk '{print $1}')"
archive_bytes="None"
if [[ "${ARTIFACT_ARCHIVE_ON_BUILD:-1}" == "1" ]]; then
  archive="$artifact_dir/$service-$VERSION-$target.tar.zst"
  log "creating normalized tar.zst archive"
  tar -C "$rootfs" -cf - . | zstd -q -19 -o "$archive"
  archive_bytes="$(wc -c < "$archive" | tr -d ' ')"
fi
portable="$(portable_flag)"
assumed_host_libs_json="$(portable_host_libs_json)"

INSTALLED_MEMBERS_JSON="$installed_members" python3 - "$manifest" <<PY
import json
import os

manifest = {
    "service": "$service",
    "version": "$VERSION",
    "platform": "$PLATFORM",
    "arch": "$ARCH",
    "target": "$target",
    "libc": "glibc" if "$TARGET_OS" == "linux" else None,
    "artifact_source": "upstream-release-archive",
    "provenance": {
        "kind": "repackaged-upstream-release",
        "repository": "$repository",
        "version": "$VERSION",
        "upstream_asset": {
            "name": "$asset_name",
            "url": "$asset_url",
            "sha256": "$expected_sha256",
        },
        "installed_members": json.loads(os.environ["INSTALLED_MEMBERS_JSON"]).get("members", {}),
    },
    "entrypoint": json.loads("""$ENTRYPOINT_JSON"""),
    "cmd": json.loads("""$CMD_JSON"""),
    "build_mode": "upstream-archive",
    "portable": "$portable" == "true",
    "assumed_host_libs": json.loads("""$assumed_host_libs_json"""),
    "runtime_requires": "${RUNTIME_REQUIRES:-}" or None,
    "smoke_command": "scripts/smoke.sh $service --artifact $rootfs",
    "archive": os.path.basename("$archive") or None,
    "sbom": os.path.basename("$sbom"),
    "licenses": "share/licenses",
    "size": {
        "rootfs_bytes": int($rootfs_kib) * 1024,
        "rootfs_mib": round((int($rootfs_kib) * 1024) / 1024 / 1024, 1),
        "archive_bytes": $archive_bytes,
        "archive_mib": round($archive_bytes / 1024 / 1024, 1) if $archive_bytes is not None else None,
    },
}

with open("$manifest", "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, indent=2, sort_keys=True)
    stream.write("\n")
PY

if [[ -n "$archive" ]]; then
  "$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" "$archive"
  sums="$artifact_dir/SHA256SUMS"
  python3 - "$archive" "$sbom" "$sums" <<'PY'
import hashlib
import os
import sys

archive_path, sbom_path, sums_path = sys.argv[1:]
with open(sums_path, "w", encoding="utf-8") as output:
    for path in (archive_path, sbom_path):
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(1 << 20), b""):
                digest.update(chunk)
        output.write(f"{digest.hexdigest()}  {os.path.basename(path)}\n")
PY
  "$ROOT_DIR/scripts/record-archive-digest.py" "$manifest" "$archive" "$sums"
else
  "$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs"
fi
log "upstream archive artifact ready: $artifact_dir"
