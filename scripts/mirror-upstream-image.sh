#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/mirror-upstream-image.sh SERVICE VERSION DESTINATION OUTPUT

Copy the pinned upstream OCI image and verify the destination's complete index
and referrer tree before proving an anonymous pull and service smoke.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 4 ]] || { usage >&2; exit 2; }

require_cmd python3
require_cmd regctl

service="$1"
version="$2"
destination="$3"
output="$4"

load_recipe "$service"
policy_file="${UPSTREAM_ASSETS_FILE:?recipe must define UPSTREAM_ASSETS_FILE}"
[[ "$policy_file" = /* ]] || policy_file="$ROOT_DIR/$policy_file"
[[ -f "$policy_file" ]] || fail "upstream asset policy not found: $policy_file"

if ! image_json="$(python3 "$ROOT_DIR/scripts/upstream-release.py" image "$policy_file" "$version")"; then
  fail "could not resolve upstream image policy for $service $version"
fi
read -r source expected_index_digest <<<"$(
  IMAGE_JSON="$image_json" python3 - <<'PY'
import json
import os

image = json.loads(os.environ["IMAGE_JSON"])
print(image["source"], image["index_digest"])
PY
)"
destination_ref="$destination:$version"
source_ref="$source@$expected_index_digest"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-oci-mirror.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT
source_raw="$work_dir/source-index.json"
destination_raw="$work_dir/destination-index.json"
tree_source="$work_dir/source-tree.txt"
tree_destination="$work_dir/destination-tree.txt"
tree_source_error="$work_dir/source-tree.error"
tree_destination_error="$work_dir/destination-tree.error"
tree_source_digests="$work_dir/source-tree-digests.txt"
tree_destination_digests="$work_dir/destination-tree-digests.txt"

log "verifying upstream image tag resolves to $expected_index_digest"
source_live_digest="$(regctl image digest "$source" | tr -d '[:space:]')"
[[ "$source_live_digest" == "$expected_index_digest" ]] || fail \
  "upstream image tag digest mismatch: expected $expected_index_digest, got $source_live_digest"

log "reading pinned upstream OCI index"
regctl image manifest --format raw-body "$source_ref" >"$source_raw"

log "copying exact upstream OCI index to $destination_ref"
regctl image copy --digest-tags --referrers "$source_ref" "$destination_ref"

destination_live_digest="$(regctl image digest "$destination_ref" | tr -d '[:space:]')"
[[ "$destination_live_digest" == "$expected_index_digest" ]] || fail \
  "destination image digest mismatch: expected $expected_index_digest, got $destination_live_digest"
regctl image manifest --format raw-body "$destination_ref@$destination_live_digest" >"$destination_raw"

artifact_tree() {
  local reference="$1"
  local tree_output="$2"
  local error_output="$3"
  if regctl artifact tree --digest-tags "$reference" >"$tree_output" 2>"$error_output"; then
    return 0
  fi
  return 1
}

if artifact_tree "$source_ref" "$tree_source" "$tree_source_error"; then
  :
else
  cat "$tree_source_error" >&2
  fail "upstream external referrer tree query failed"
fi

if artifact_tree \
  "$destination_ref@$destination_live_digest" "$tree_destination" "$tree_destination_error"; then
  :
else
  cat "$tree_destination_error" >&2
  fail "destination external referrer tree query failed"
fi

python3 - "$tree_source" "$tree_source_digests" <<'PY'
import pathlib
import re
import sys

path, output = map(pathlib.Path, sys.argv[1:])
digests = sorted(set(re.findall(r"sha256:[0-9a-f]{64}", path.read_text(encoding="utf-8"))))
output.write_text("\n".join(digests) + ("\n" if digests else ""), encoding="utf-8")
PY
python3 - "$tree_destination" "$tree_destination_digests" <<'PY'
import pathlib
import re
import sys

path, output = map(pathlib.Path, sys.argv[1:])
digests = sorted(set(re.findall(r"sha256:[0-9a-f]{64}", path.read_text(encoding="utf-8"))))
output.write_text("\n".join(digests) + ("\n" if digests else ""), encoding="utf-8")
PY
cmp -s "$tree_source_digests" "$tree_destination_digests" || fail \
  "destination external referrer tree differs from upstream"
log "external referrer tree matches"

"$ROOT_DIR/scripts/verify-oci-mirror.py" \
  "$policy_file" "$version" "$source_raw" "$destination_raw" "$output"

python3 - "$output" "$service" "$source_ref" "$destination_ref" "$tree_source_digests" <<'PY'
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[1])
service, source, destination, tree_digests = sys.argv[2:]
tree_digests = pathlib.Path(tree_digests)
with output.open(encoding="utf-8") as stream:
    provenance = json.load(stream)
provenance["service"] = service
provenance["destination"] = destination
provenance["source_ref"] = source
if tree_digests.exists():
    provenance["external_referrers"] = [
        line for line in tree_digests.read_text(encoding="utf-8").splitlines() if line
    ]
with output.open("w", encoding="utf-8") as stream:
    json.dump(provenance, stream, indent=2, sort_keys=True)
    stream.write("\n")
PY

anonymous_regctl_config="$(mktemp -d "$work_dir/anonymous-regctl.XXXXXX")"
anonymous_docker_config="$(mktemp -d "$work_dir/anonymous-docker.XXXXXX")"
log "proving anonymous destination resolution"
anonymous_digest="$(
  REGCTL_CONFIG="$anonymous_regctl_config" \
  DOCKER_CONFIG="$anonymous_docker_config" \
    regctl image digest "$destination_ref" | tr -d '[:space:]'
)"
[[ "$anonymous_digest" == "$expected_index_digest" ]] || fail \
  "anonymous destination digest mismatch: expected $expected_index_digest, got $anonymous_digest"

if [[ "${IMAGE_RELEASE_MODE:-derived}" == "mirror" ]]; then
  require_cmd docker
  log "proving anonymous destination pull and $service image smoke"
  DOCKER_CONFIG="$anonymous_docker_config" docker pull "$destination_ref"
  if [[ -n "${MIRROR_SMOKE_SCRIPT:-}" ]]; then
    smoke_script="$MIRROR_SMOKE_SCRIPT"
    [[ "$smoke_script" = /* ]] || smoke_script="$ROOT_DIR/$smoke_script"
    [[ -x "$smoke_script" ]] || fail "mirror smoke script is not executable: $smoke_script"
    DOCKER_CONFIG="$anonymous_docker_config" IMAGE="$destination_ref" \
      "$smoke_script"
  else
    DOCKER_CONFIG="$anonymous_docker_config" \
      "$ROOT_DIR/scripts/smoke.sh" "$service" --image "$destination_ref"
  fi
else
  log "skipping mirror image smoke for service $service"
fi

log "exact OCI mirror verified: $destination_ref"
