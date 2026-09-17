#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/publish-native-oci.sh SERVICE VERSION IMAGE_REPOSITORY ASSETS_DIR [OUTPUT_JSON]

Push each native triplet (tar.zst + manifest.json + SHA256SUMS) to
IMAGE_REPOSITORY:<VERSION>-native-<target>. Do not use <VERSION>-linux-*
tags; those are image platform manifests. Writes OUTPUT_JSON
(default: published-natives.json) as [{tag,digest}, ...]. Missing
platforms are skipped. Never prune untagged manifests.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 4 && $# -le 5 ]] || { usage >&2; exit 2; }

SERVICE="$1"
VERSION="$2"
IMAGE_REPOSITORY="$3"
ASSETS_DIR="$4"
OUTPUT_JSON="${5:-published-natives.json}"

[[ -d "$ASSETS_DIR" ]] || fail "assets directory not found: $ASSETS_DIR"
[[ "$SERVICE" =~ ^[a-z][a-z0-9-]*$ ]] || fail "invalid service name: $SERVICE"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid version: $VERSION"

require_cmd python3
require_cmd regctl

ARCHIVE_TYPE="application/vnd.supabase.slim.archive.v1.tar+zstd"
MANIFEST_TYPE="application/vnd.supabase.slim.manifest.v1+json"
CHECKSUM_TYPE="application/vnd.supabase.slim.checksum.v1"
ARTIFACT_TYPE="application/vnd.supabase.slim.native.v1"
TARGETS=(linux-arm64 linux-amd64 darwin-arm64)

tmp_tsv="$(mktemp "${TMPDIR:-/tmp}/slim-native-oci.XXXXXX")"
trap 'rm -f "$tmp_tsv"' EXIT

for target in "${TARGETS[@]}"; do
  archive="$ASSETS_DIR/$SERVICE-$VERSION-$target.tar.zst"
  manifest="$ASSETS_DIR/$SERVICE-$VERSION-$target.manifest.json"
  checksum="$ASSETS_DIR/$SERVICE-$VERSION-$target.SHA256SUMS"
  if [[ ! -f "$archive" || ! -f "$manifest" || ! -f "$checksum" ]]; then
    log "skipping $target: native triplet not in $ASSETS_DIR"
    continue
  fi
  tag="$VERSION-native-$target"
  ref="$IMAGE_REPOSITORY:$tag"
  log "publishing $ref"
  regctl artifact put \
    --artifact-type "$ARTIFACT_TYPE" \
    --file "$archive" --file-media-type "$ARCHIVE_TYPE" \
    --file "$manifest" --file-media-type "$MANIFEST_TYPE" \
    --file "$checksum" --file-media-type "$CHECKSUM_TYPE" \
    "$ref"
  digest="$(regctl manifest head "$ref" | tr -d '[:space:]')"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "could not resolve digest for $ref"
  printf '%s\t%s\n' "$tag" "$digest" >> "$tmp_tsv"
done

python3 - "$tmp_tsv" "$OUTPUT_JSON" <<'PY'
import json
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        tag, digest = line.split("\t", 1)
        rows.append({"tag": tag, "digest": digest})
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(rows, fh, indent=2)
    fh.write("\n")
PY

log "wrote $OUTPUT_JSON"
