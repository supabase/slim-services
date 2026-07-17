#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SERVICE_RELEASE_CONFIG:-$ROOT_DIR/.github/service-release-sources.json}"
TARGET_REPOSITORY="${GITHUB_REPOSITORY:-supabase/slim-services}"
TARGET_REF="${SERVICE_RELEASE_REF:-${GITHUB_REF_NAME:-main}}"
TARGET_WORKFLOW="${SERVICE_RELEASE_WORKFLOW:-service-release.yml}"
POLL_SERVICE="${POLL_SERVICE:-}"
POLL_DRY_RUN="${POLL_DRY_RUN:-0}"

command -v gh >/dev/null 2>&1 || {
  printf 'required command not found: gh\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'required command not found: python3\n' >&2
  exit 1
}
[[ -f "$CONFIG_FILE" ]] || {
  printf 'service release config not found: %s\n' "$CONFIG_FILE" >&2
  exit 1
}

if [[ "${1:-}" == "--validate-config" ]]; then
  python3 - "$CONFIG_FILE" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

services = data.get("services")
if not isinstance(services, dict) or not services:
    raise SystemExit("config must contain a non-empty services object")

for service, config in services.items():
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", service):
        raise SystemExit(f"invalid service name: {service}")
    repository = config.get("repository", "")
    if not re.fullmatch(r"[^/]+/[^/]+", repository):
        raise SystemExit(f"invalid repository for {service}: {repository}")
    re.compile(config.get("tag_pattern", ""))

print(f"validated {len(services)} service release sources")
PY
  exit 0
fi

[[ -n "${GH_TOKEN:-}" ]] || {
  printf 'GH_TOKEN is required to query releases and dispatch workflows\n' >&2
  exit 1
}

while IFS=$'\t' read -r service upstream_repository tag_pattern; do
  [[ -z "$POLL_SERVICE" || "$service" == "$POLL_SERVICE" ]] || continue

  version="$(gh api "repos/$upstream_repository/releases/latest" --jq .tag_name)"
  if [[ ! "$version" =~ $tag_pattern ]]; then
    printf 'ignoring %s latest release %s: does not match %s\n' \
      "$service" "$version" "$tag_pattern" >&2
    continue
  fi

  release_tag="$service-$version"
  if gh release view "$release_tag" --repo "$TARGET_REPOSITORY" >/dev/null 2>&1; then
    printf '%s is already published as %s\n' "$service" "$release_tag"
    continue
  fi

  if [[ "$POLL_DRY_RUN" == "1" ]]; then
    printf 'would dispatch %s for %s %s on %s\n' \
      "$TARGET_WORKFLOW" "$service" "$version" "$TARGET_REF"
    continue
  fi

  printf 'dispatching %s for %s %s on %s\n' \
    "$TARGET_WORKFLOW" "$service" "$version" "$TARGET_REF"
  gh workflow run "$TARGET_WORKFLOW" \
    --repo "$TARGET_REPOSITORY" \
    --ref "$TARGET_REF" \
    -f "service=$service" \
    -f "version=$version" \
    -f force=false
done < <(
  python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    services = json.load(fh)["services"]

for service, config in services.items():
    if config.get("poll"):
        print(service, config["repository"], config["tag_pattern"], sep="\t")
PY
)
