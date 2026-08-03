#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SERVICE_RELEASE_CONFIG:-$ROOT_DIR/.github/service-release-sources.json}"
TARGET_REPOSITORY="${RELEASE_RESULTS_REPOSITORY:-${GITHUB_REPOSITORY:-supabase/slim-services}}"
ARTIFACTS_DIR="${RESULTS_ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"

command -v gh >/dev/null 2>&1 || {
  printf 'required command not found: gh\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'required command not found: python3\n' >&2
  exit 1
}
[[ -n "${GH_TOKEN:-}" ]] || {
  printf 'GH_TOKEN is required to query and download releases\n' >&2
  exit 1
}
[[ -f "$CONFIG_FILE" ]] || {
  printf 'service release config not found: %s\n' "$CONFIG_FILE" >&2
  exit 1
}

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

gh api --paginate --slurp \
  "repos/$TARGET_REPOSITORY/releases?per_page=100" \
  > "$temp_dir/releases.json"

python3 - "$CONFIG_FILE" "$temp_dir/releases.json" \
  > "$temp_dir/latest-releases.tsv" <<'PY'
import json
import re
import sys

config_path, releases_path = sys.argv[1:]
with open(config_path, encoding="utf-8") as fh:
    services = json.load(fh)["services"]
with open(releases_path, encoding="utf-8") as fh:
    release_pages = json.load(fh)

releases = [release for page in release_pages for release in page]
for service, config in services.items():
    pattern = re.compile(config["tag_pattern"])
    prefix = f"{service}-"
    candidates = []
    for release in releases:
        tag = release.get("tag_name", "")
        if release.get("draft") or release.get("prerelease") or not tag.startswith(prefix):
            continue
        version = tag[len(prefix):]
        if not pattern.fullmatch(version):
            continue
        numeric_version = tuple(int(part) for part in re.findall(r"\d+", version))
        candidates.append((numeric_version, tag, version))

    if not candidates:
        print(f"no published release found for {service}", file=sys.stderr)
        continue

    _, tag, version = max(candidates)
    print(service, tag, version, sep="\t")
PY

while IFS=$'\t' read -r service release_tag version; do
  [[ -n "$service" ]] || continue
  printf 'downloading manifests for %s (%s)\n' "$service" "$release_tag"
  download_dir=""
  for attempt in 1 2 3 4; do
    attempt_dir="$temp_dir/manifests/$service/$attempt"
    mkdir -p "$attempt_dir"
    if gh release download "$release_tag" \
      --repo "$TARGET_REPOSITORY" \
      --pattern '*.manifest.json' \
      --dir "$attempt_dir"; then
      download_dir="$attempt_dir"
      break
    fi
    if [[ "$attempt" == "4" ]]; then
      printf 'could not download manifests for %s after %s attempts\n' \
        "$release_tag" "$attempt" >&2
      exit 1
    fi
    retry_delay=$((1 << attempt))
    printf 'release download failed; retrying in %ss (%s/4)\n' \
      "$retry_delay" "$attempt" >&2
    sleep "$retry_delay"
  done

  python3 - "$ARTIFACTS_DIR" "$download_dir" "$service" "$version" <<'PY'
import glob
import json
import os
import shutil
import sys

artifacts_dir, download_dir, expected_service, expected_version = sys.argv[1:]
required_platforms = {"linux-arm64", "darwin-arm64"}
found_platforms = set()

for path in glob.glob(os.path.join(download_dir, "*.manifest.json")):
    with open(path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    service = manifest.get("service")
    version = manifest.get("version")
    platform_dir = (manifest.get("platform") or "").replace("/", "-")
    if service != expected_service or version != expected_version or not platform_dir:
        raise SystemExit(
            f"unexpected manifest metadata in {path}: "
            f"{service=} {version=} {platform_dir=}"
        )
    destination = os.path.join(artifacts_dir, service, version, platform_dir)
    os.makedirs(destination, exist_ok=True)
    shutil.copy(path, os.path.join(destination, "manifest.json"))
    found_platforms.add(platform_dir)
    print(f"placed {service} {version} {platform_dir}")

missing = required_platforms - found_platforms
if missing:
    raise SystemExit(
        f"release {expected_service}-{expected_version} is missing manifests: "
        + ", ".join(sorted(missing))
    )
PY
done < "$temp_dir/latest-releases.tsv"
