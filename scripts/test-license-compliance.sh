#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/slim-license-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

rootfs="$fixture/rootfs"
mkdir -p "$rootfs/app/node_modules/example" "$rootfs/app/docs" "$rootfs/bin"
printf 'example dependency license\n' > "$rootfs/app/node_modules/example/LICENSE"
printf 'runtime documentation\n' > "$rootfs/app/docs/manual.md"
printf 'runtime\n' > "$rootfs/bin/service"

"$ROOT_DIR/scripts/prune-runtime-tree.sh" "$rootfs"

test -f "$rootfs/share/licenses/slim-services/LICENSE"
test -f "$rootfs/share/licenses/slim-services/THIRD_PARTY_NOTICES.md"
test -f "$rootfs/share/licenses/app/node_modules/example/LICENSE"
test ! -e "$rootfs/app/node_modules/example/LICENSE"
test ! -e "$rootfs/app/docs"
test -f "$rootfs/bin/service"

sbom="$fixture/artifact.sbom.spdx.json"
SOURCE_DATE_EPOCH=0 "$ROOT_DIR/scripts/generate-artifact-sbom.sh" \
  "$rootfs" "$sbom" storage v1.0.0 linux-amd64

python3 - "$sbom" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    sbom = json.load(stream)

assert sbom["spdxVersion"] == "SPDX-2.3"
assert sbom["dataLicense"] == "CC0-1.0"
assert sbom["creationInfo"]["created"] == "1970-01-01T00:00:00Z"
file_names = {entry["fileName"] for entry in sbom["files"]}
assert "./share/licenses/slim-services/LICENSE" in file_names
assert "./share/licenses/app/node_modules/example/LICENSE" in file_names
assert "./bin/service" in file_names
PY

echo "license compliance test passed"
