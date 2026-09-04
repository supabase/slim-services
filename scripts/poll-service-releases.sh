#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SERVICE_RELEASE_CONFIG:-$ROOT_DIR/.github/service-release-sources.json}"
TARGET_REPOSITORY="${GITHUB_REPOSITORY:-supabase/slim-services}"
TARGET_REF="${SERVICE_RELEASE_REF:-${GITHUB_REF_NAME:-main}}"
TARGET_WORKFLOW="${SERVICE_RELEASE_WORKFLOW:-service-release.yml}"
POLL_SERVICE="${POLL_SERVICE:-}"
POLL_DRY_RUN="${POLL_DRY_RUN:-0}"
POLL_RETRY_COOLDOWN_SECONDS="${POLL_RETRY_COOLDOWN_SECONDS:-21600}"
POLL_SUCCESS_GRACE_SECONDS="${POLL_SUCCESS_GRACE_SECONDS:-600}"
POLL_MAX_DISPATCHES_PER_SERVICE="${POLL_MAX_DISPATCHES_PER_SERVICE:-3}"
POLL_MAX_ACTIVE_RELEASES="${POLL_MAX_ACTIVE_RELEASES:-12}"
DOCKER_HUB_API_BASE="${DOCKER_HUB_API_BASE:-https://hub.docker.com/v2}"
DOCKER_HUB_API_BASE="${DOCKER_HUB_API_BASE%/}"

for positive_integer in \
  POLL_MAX_DISPATCHES_PER_SERVICE \
  POLL_MAX_ACTIVE_RELEASES; do
  value="${!positive_integer}"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s must be a positive integer: %s\n' "$positive_integer" "$value" >&2
    exit 1
  fi
done

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
  python3 - "$CONFIG_FILE" "$ROOT_DIR" <<'PY'
import json
import pathlib
import re
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
root = pathlib.Path(sys.argv[2]).resolve()

services = data.get("services")
if not isinstance(services, dict) or not services:
    raise SystemExit("config must contain a non-empty services object")

for service, config in services.items():
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", service):
        raise SystemExit(f"invalid service name: {service}")
    repository = config.get("repository", "")
    if not re.fullmatch(r"[^/]+/[^/]+", repository):
        raise SystemExit(f"invalid repository for {service}: {repository}")
    tag_pattern = config.get("tag_pattern", "")
    re.compile(tag_pattern)
    if not tag_pattern.startswith("^") or not tag_pattern.endswith("$"):
        raise SystemExit(f"tag pattern must be anchored for {service}: {tag_pattern}")
    if not isinstance(config.get("poll"), bool):
        raise SystemExit(f"poll must be a boolean for {service}")
    release_floor = config.get("release_floor")
    release_source = config.get("release_source", "github")
    release_lines = config.get("release_lines")
    if (
        config.get("poll") is True
        and not config.get("external_release_descriptor")
        and release_lines is None
    ):
        if not isinstance(release_floor, str) or not re.fullmatch(tag_pattern, release_floor):
            raise SystemExit(
                f"release_floor must match tag_pattern for polled service {service}: "
                f"{release_floor}"
            )
    if release_lines is not None:
        if release_source != "dockerhub":
            raise SystemExit(
                f"release_lines requires Docker Hub releases for {service}"
            )
        if not isinstance(release_lines, list) or not release_lines:
            raise SystemExit(f"release_lines must be a non-empty list for {service}")
        for index, line in enumerate(release_lines):
            if not isinstance(line, dict):
                raise SystemExit(f"release_lines[{index}] must be an object for {service}")
            line_pattern = line.get("tag_pattern", "")
            if not isinstance(line_pattern, str):
                raise SystemExit(f"release_lines[{index}].tag_pattern must be a string for {service}")
            try:
                re.compile(line_pattern)
            except re.error as error:
                raise SystemExit(
                    f"invalid release_lines[{index}].tag_pattern for {service}: {error}"
                ) from error
            if not line_pattern.startswith("^") or not line_pattern.endswith("$"):
                raise SystemExit(
                    f"release_lines[{index}].tag_pattern must be anchored for {service}: {line_pattern}"
                )
            line_floor = line.get("release_floor")
            if not isinstance(line_floor, str) or not re.fullmatch(line_pattern, line_floor):
                raise SystemExit(
                    f"release_lines[{index}].release_floor must match its tag_pattern for {service}: {line_floor}"
                )
            if not re.fullmatch(tag_pattern, line_floor):
                raise SystemExit(
                    f"release_lines[{index}].release_floor must match the service tag_pattern for {service}: {line_floor}"
                )
    if release_source not in {"github", "dockerhub"}:
        raise SystemExit(f"unsupported release source for {service}: {release_source}")
    artifact_source = config.get("artifact_source", "source")
    if artifact_source not in {"source", "upstream-archive", "external-source"}:
        raise SystemExit(f"unsupported artifact source for {service}: {artifact_source}")
    image_release = config.get("image_release", "derived")
    if image_release not in {"derived", "mirror"}:
        raise SystemExit(f"unsupported image release mode for {service}: {image_release}")
    image_repository = config.get("image_repository", "")
    if release_source == "dockerhub" or image_release == "mirror":
        if not re.fullmatch(r"[^/]+/[^/]+", image_repository):
            message = (
                "invalid Docker Hub image repository"
                if release_source == "dockerhub"
                else "invalid mirror image repository"
            )
            raise SystemExit(
                f"{message} for {service}: {image_repository}"
            )
    source_ref_tag_pattern = config.get("source_ref_tag_pattern")
    if source_ref_tag_pattern is not None:
        if release_source != "dockerhub":
            raise SystemExit(
                f"source_ref_tag_pattern requires Docker Hub releases for {service}"
            )
        if not isinstance(source_ref_tag_pattern, str):
            raise SystemExit(
                f"source_ref_tag_pattern must be a string for {service}"
            )
        try:
            source_ref_pattern = re.compile(source_ref_tag_pattern)
        except re.error as error:
            raise SystemExit(
                f"invalid source_ref_tag_pattern for {service}: {error}"
            ) from error
        if source_ref_pattern.groups != 1:
            raise SystemExit(
                f"source_ref_tag_pattern must contain exactly one capture group for {service}"
            )
    descriptor = config.get("external_release_descriptor")
    if descriptor is not None:
        if not isinstance(descriptor, str) or not descriptor:
            raise SystemExit(f"external_release_descriptor must be a non-empty path for {service}")
        if config.get("poll") is True:
            raise SystemExit(f"external descriptor service must set poll=false for {service}")
        descriptor_path = root / descriptor
        if not descriptor_path.is_file() or descriptor_path.is_symlink():
            raise SystemExit(f"external descriptor not found for {service}: {descriptor_path}")

print(f"validated {len(services)} service release sources")
PY
  exit 0
fi

[[ -n "${GH_TOKEN:-}" ]] || {
  printf 'GH_TOKEN is required to query releases and dispatch workflows\n' >&2
  exit 1
}

poll_configs="$(python3 - "$CONFIG_FILE" "$POLL_SERVICE" <<'PY'
import json
import sys

config_file, selected_service = sys.argv[1:]
with open(config_file, encoding="utf-8") as fh:
    services = json.load(fh)["services"]

for service, config in services.items():
    if selected_service and service != selected_service:
        continue
    if config.get("poll") is True and not config.get("external_release_descriptor"):
        print(
            service,
            config["repository"],
            config["tag_pattern"],
            config.get("release_floor", "-"),
            config.get("release_source", "github"),
            config.get("image_repository", "-"),
            json.dumps(config.get("release_lines", []), separators=(",", ":")),
            sep="\t",
        )
PY
)"
[[ -n "$poll_configs" ]] || exit 0

published_release_tags="$(
  gh api --paginate "repos/$TARGET_REPOSITORY/releases?per_page=100" \
    --jq '.[].tag_name'
)"
runs_json="$(
  gh run list \
    --repo "$TARGET_REPOSITORY" \
    --workflow "$TARGET_WORKFLOW" \
    --limit 100 \
    --json displayTitle,status,conclusion,createdAt,updatedAt
)"
active_release_count="$(RUNS_JSON="$runs_json" python3 - <<'PY'
import json
import os

active_statuses = {"in_progress", "pending", "queued", "requested", "waiting"}
print(
    sum(
        run.get("status") in active_statuses
        for run in json.loads(os.environ["RUNS_JSON"])
    )
)
PY
)"

while IFS=$'\t' read -r service upstream_repository tag_pattern release_floor release_source upstream_image_repository release_lines_json; do
  service_dispatch_count=0
  versions=""
  if [[ "$release_source" == "dockerhub" ]]; then
    if ! versions="$(python3 - \
      "$upstream_image_repository" \
      "$tag_pattern" \
      "$release_floor" \
      "$release_lines_json" \
      "$DOCKER_HUB_API_BASE" <<'PY'
import json
import re
import sys
import urllib.parse
import urllib.request

repository, pattern_raw, release_floor, release_lines_raw, docker_hub_api_base = sys.argv[1:]
pattern = re.compile(pattern_raw)
release_lines = json.loads(release_lines_raw) if release_lines_raw else []

def version_key(value):
    return tuple(
        (0, int(part)) if part.isdigit() else (1, part)
        for part in re.findall(r"\d+|\D+", value)
    )

url = (
    f"{docker_hub_api_base.rstrip('/')}/repositories/"
    f"{urllib.parse.quote(repository, safe='/')}/tags?page_size=100&ordering=last_updated"
)
candidates = []
for _ in range(10):
    with urllib.request.urlopen(url, timeout=30) as response:
        page = json.load(response)
    for tag in page.get("results", []):
        candidate = tag.get("name", "")
        if pattern.fullmatch(candidate):
            candidates.append(candidate)
    url = page.get("next")
    if not url:
        break
if release_lines:
    line_patterns = [
        (re.compile(line["tag_pattern"]), line["release_floor"])
        for line in release_lines
    ]
    eligible = set()
    for candidate in candidates:
        matching = [
            line_floor
            for line_pattern, line_floor in line_patterns
            if line_pattern.fullmatch(candidate)
        ]
        if len(matching) != 1:
            raise SystemExit(
                f"candidate {candidate} matched {len(matching)} release lines; expected exactly one"
            )
        if version_key(candidate) >= version_key(matching[0]):
            eligible.add(candidate)
    for line in release_lines:
        line_floor = line["release_floor"]
        if line_floor not in candidates:
            raise SystemExit(1)
else:
    if release_floor not in candidates:
        raise SystemExit(1)
    floor_key = version_key(release_floor)
    eligible = {candidate for candidate in candidates if version_key(candidate) >= floor_key}
print(
    *sorted(
        eligible,
        key=version_key,
    ),
    sep="\n",
)
PY
    )"; then
      printf 'could not reconcile Docker Hub tags for %s from floor %s (%s); continuing\n' \
        "$service" "$release_floor" "$upstream_image_repository" >&2
      continue
    fi
  else
    if ! release_tags="$(
      gh api --paginate "repos/$upstream_repository/releases?per_page=100" \
        --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name'
    )"; then
      printf 'could not query stable releases for %s (%s); continuing\n' \
        "$service" "$upstream_repository" >&2
      continue
    fi

    if ! versions="$(RELEASE_TAGS="$release_tags" python3 - "$tag_pattern" "$release_floor" <<'PY'
import os
import re
import sys

pattern_raw, release_floor = sys.argv[1:]
release_tags = os.environ["RELEASE_TAGS"]
pattern = re.compile(pattern_raw)

def version_key(value):
    return tuple(
        (0, int(part)) if part.isdigit() else (1, part)
        for part in re.findall(r"\d+|\D+", value)
    )

candidates = {
    line.strip()
    for line in release_tags.splitlines()
    if pattern.fullmatch(line.strip())
}
if release_floor not in candidates:
    raise SystemExit(1)
floor_key = version_key(release_floor)
eligible = {candidate for candidate in candidates if version_key(candidate) >= floor_key}
print(
    *sorted(
        eligible,
        key=version_key,
    ),
    sep="\n",
)
PY
    )"; then
      printf 'release floor %s was not found for %s (%s); continuing\n' \
        "$release_floor" "$service" "$upstream_repository" >&2
      continue
    fi
  fi

  if [[ -z "$versions" ]]; then
    printf 'no stable release tags for %s match %s from floor %s\n' \
      "$service" "$tag_pattern" "$release_floor" >&2
    continue
  fi

  while IFS= read -r version; do
    release_tag="$service-$version"
    if grep -Fxq "$release_tag" <<< "$published_release_tags"; then
      printf '%s is already published as %s\n' "$service" "$release_tag"
      continue
    fi

    expected_run_title="Release $service $version"
    run_state="$(RUNS_JSON="$runs_json" python3 - \
      "$expected_run_title" \
      "$POLL_RETRY_COOLDOWN_SECONDS" \
      "$POLL_SUCCESS_GRACE_SECONDS" <<'PY'
import datetime
import json
import os
import sys

expected_title, cooldown_raw, success_grace_raw = sys.argv[1:]
runs_raw = os.environ["RUNS_JSON"]
cooldown = int(cooldown_raw)
success_grace = int(success_grace_raw)
active_statuses = {"in_progress", "pending", "queued", "requested", "waiting"}
runs = json.loads(runs_raw)
matching = [run for run in runs if run.get("displayTitle") == expected_title]
if any(run.get("status") in active_statuses for run in matching):
    print("active")
    raise SystemExit(0)

def timestamp(run):
    raw = run.get("updatedAt") or run.get("createdAt")
    return datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))

completed = [
    run
    for run in matching
    if run.get("status") == "completed" and (run.get("updatedAt") or run.get("createdAt"))
]
if completed:
    latest = max(completed, key=timestamp)
    completed_at = timestamp(latest)
    now = datetime.datetime.now(datetime.timezone.utc)
    age = (now - completed_at).total_seconds()
    if latest.get("conclusion") == "success" and age < success_grace:
        print("settling")
        raise SystemExit(0)
    if latest.get("conclusion") != "success" and age < cooldown:
        print("cooling")
        raise SystemExit(0)

print("eligible")
PY
    )"
    if [[ "$run_state" == "active" ]]; then
      printf '%s is already being built by %s\n' "$service" "$expected_run_title"
      continue
    fi
    if [[ "$run_state" == "cooling" ]]; then
      printf '%s is cooling down after a recent unsuccessful attempt by %s\n' \
        "$service" "$expected_run_title"
      continue
    fi
    if [[ "$run_state" == "settling" ]]; then
      printf '%s is waiting for release publication after successful run %s\n' \
        "$service" "$expected_run_title"
      continue
    fi

    if (( active_release_count >= POLL_MAX_ACTIVE_RELEASES )); then
      printf 'global active release limit %s reached; not dispatching more releases\n' \
        "$POLL_MAX_ACTIVE_RELEASES"
      break
    fi

    if [[ "$POLL_DRY_RUN" == "1" ]]; then
      printf 'would dispatch %s for %s stable release %s on %s\n' \
        "$TARGET_WORKFLOW" "$service" "$version" "$TARGET_REF"
    else
      printf 'dispatching %s for %s stable release %s on %s\n' \
        "$TARGET_WORKFLOW" "$service" "$version" "$TARGET_REF"
      gh workflow run "$TARGET_WORKFLOW" \
        --repo "$TARGET_REPOSITORY" \
        --ref "$TARGET_REF" \
        -f "service=$service" \
        -f "version=$version" \
        -f force=false
    fi

    service_dispatch_count=$((service_dispatch_count + 1))
    active_release_count=$((active_release_count + 1))
    if (( service_dispatch_count >= POLL_MAX_DISPATCHES_PER_SERVICE )); then
      break
    fi
  done <<< "$versions"
done <<< "$poll_configs"
