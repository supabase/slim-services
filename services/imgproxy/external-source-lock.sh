#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'imgproxy source lock requires %s\n' "$1" >&2
    exit 2
  }
}
require_cmd python3
require_cmd nix-build

# The resolver deliberately passes only the immutable source record. The
# version is used only for derivation naming; source and repository values come
# from that record.
service_version="${IMGPROXY_VERSION:-source-lock}"
record="$(cat)"

IFS=$'\t' read -r source_commit source_hash source_repository < <(SOURCE_RECORD="$record" python3 - <<'PY'
import json
import os
from urllib.parse import urlparse

record = json.loads(os.environ["SOURCE_RECORD"])
required = ("commit", "url", "sha256", "fetch_from_github_hash")
missing = [key for key in required if not isinstance(record.get(key), str) or not record[key]]
if missing:
    raise SystemExit("source record missing: " + ",".join(missing))
parsed = urlparse(record["url"])
parts = [part for part in parsed.path.split("/") if part]
if parsed.scheme != "https" or parsed.netloc != "github.com" or len(parts) < 4 or parts[2] != "archive":
    raise SystemExit("source record url must be a GitHub archive URL")
print("\t".join((record["commit"], record["fetch_from_github_hash"], f"{parts[0]}/{parts[1]}")))
PY
)
[[ -n "$source_commit" && -n "$source_hash" && -n "$source_repository" ]] || {
  printf 'imgproxy source lock could not parse source record\n' >&2
  exit 1
}
fake_vendor_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
log_file="$(mktemp "${TMPDIR:-/tmp}/imgproxy-source-lock.XXXXXX")"
trap 'rm -f "$log_file"' EXIT

set +e
nix-build "$ROOT_DIR/services/imgproxy/nix" \
  -A goModules \
  --argstr serviceVersion "$service_version" \
  --argstr sourceRepository "$source_repository" \
  --argstr sourceCommit "$source_commit" \
  --argstr sourceHash "$source_hash" \
  --argstr vendorHash "$fake_vendor_hash" \
  --no-out-link >"$log_file" 2>&1
probe_status=$?
set -e

if [[ "$probe_status" -eq 0 ]]; then
  printf 'imgproxy source lock probe unexpectedly accepted lib.fakeHash\n' >&2
  exit 1
fi
vendor_hash="$(sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+\/=]+).*/\1/p' "$log_file" | tail -n 1)"
if [[ -z "$vendor_hash" ]]; then
  cat "$log_file" >&2
  printf 'imgproxy source lock probe failed without a vendor hash\n' >&2
  exit "$probe_status"
fi

printf '{"vendorHash":"%s"}\n' "$vendor_hash"
