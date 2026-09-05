#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nix.sh
source "$ROOT_DIR/scripts/nix.sh"
require_cmd nix
require_cmd python3
release_dir="$(mktemp -d "${TMPDIR:-/tmp}/imgproxy-source-lock.XXXXXX")"
trap 'rm -rf "$release_dir"' EXIT
record="$(cat)"
python3 - "$release_dir/release.json" "${IMGPROXY_VERSION:-source-lock}" "$record" <<'PY'
import json, sys
from urllib.parse import urlparse
path, version, record = sys.argv[1:]
source = json.loads(record)
for name in ("commit", "url", "sha256", "fetch_from_github_hash"):
    if not isinstance(source.get(name), str) or not source[name]:
        raise SystemExit(f"imgproxy source record missing {name}")
url = urlparse(source["url"])
parts = url.path.strip("/").split("/")
if url.scheme != "https" or url.netloc != "github.com" or len(parts) < 4 or parts[2] != "archive":
    raise SystemExit("imgproxy source URL must be a GitHub archive")
with open(path, "w", encoding="utf-8") as stream:
    json.dump({"service": "imgproxy", "version": version, "source": source,
               "sourceRepository": "/".join(parts[:2]), "hashes": {}}, stream)
PY
vendor_hash="$(nix_probe_hash "$release_dir" "$(nix_system_for "$(host_os)" "$(target_arch)")" vendorHash)"
printf '{"vendorHash":"%s"}\n' "$vendor_hash"
