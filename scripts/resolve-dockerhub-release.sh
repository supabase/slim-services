#!/usr/bin/env bash
set -euo pipefail

image_repository="${1:-}"
version="${2:-}"
source_repository="${3:-}"
source_ref_tag_pattern="${4:-}"
docker_hub_api_base="${DOCKER_HUB_API_BASE:-https://hub.docker.com/v2}"
docker_hub_api_base="${docker_hub_api_base%/}"

[[ "$image_repository" =~ ^[^/]+/[^/]+$ ]] || {
  printf 'invalid Docker Hub image repository: %s\n' "$image_repository" >&2
  exit 1
}
[[ -n "$version" ]] || {
  printf 'Docker Hub version is required\n' >&2
  exit 1
}
[[ "$source_repository" =~ ^[^/]+/[^/]+$ ]] || {
  printf 'invalid GitHub source repository: %s\n' "$source_repository" >&2
  exit 1
}

for command in curl docker gh jq python3; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'required command not found: %s\n' "$command" >&2
    exit 1
  }
done

upstream_tag="$(
  curl -fsSL \
    "$docker_hub_api_base/repositories/$image_repository/tags/$version" \
    | jq -er '.name | strings'
)" || {
  printf '%s is not a published Docker Hub tag of %s\n' \
    "$version" "$image_repository" >&2
  exit 1
}
[[ "$upstream_tag" == "$version" ]] || {
  printf 'unexpected Docker Hub tag response for %s: %s\n' \
    "$version" "$upstream_tag" >&2
  exit 1
}

provenance="$(
  docker buildx imagetools inspect \
    "$image_repository:$version" \
    --format '{{json .Provenance}}'
)"
source_refs="$(
  jq -r '.. | objects | .sha1? // empty' <<< "$provenance" \
    | grep -E '^[0-9a-f]{40}$' \
    | sort -u \
    || true
)"
source_ref_count="$(printf '%s\n' "$source_refs" | grep -c . || true)"
[[ "$source_ref_count" == "1" ]] || {
  printf 'expected one source commit in %s:%s provenance\n' \
    "$image_repository" "$version" >&2
  exit 1
}
source_ref="$source_refs"

if [[ -n "$source_ref_tag_pattern" ]]; then
  expected_source_ref="$(python3 - "$source_ref_tag_pattern" "$version" <<'PY'
import re
import sys

pattern = re.compile(sys.argv[1])
if pattern.groups != 1:
    raise SystemExit("source_ref_tag_pattern must contain exactly one capture group")
match = pattern.search(sys.argv[2])
if match is None or not re.fullmatch(r"[0-9a-f]{7,40}", match.group(1)):
    raise SystemExit("Docker tag does not contain a valid source ref")
print(match.group(1))
PY
  )"
  [[ "$source_ref" == "$expected_source_ref"* ]] || {
    printf 'Docker tag source ref %s disagrees with provenance %s\n' \
      "$expected_source_ref" "$source_ref" >&2
    exit 1
  }
fi

gh api "repos/$source_repository/commits/$source_ref" --silent || {
  printf 'could not resolve source commit %s in %s\n' \
    "$source_ref" "$source_repository" >&2
  exit 1
}

printf '%s\n' "$source_ref"
