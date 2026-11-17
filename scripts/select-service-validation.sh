#!/usr/bin/env bash
# Select the {service, version} pairs pull request validation must build.
#
#   select-service-validation.sh BASE_REV HEAD_REV
#
# Run from a git checkout where both revisions exist. Prints
# {"include":[{"service":"...","version":"..."},...]} on stdout (the include
# list may be empty) and a human-readable summary on stderr. The affected
# services come from the changed paths; the versions come from the release
# poller's --validation-versions mode so both stay on one source of truth.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${SERVICE_RELEASE_CONFIG:-$ROOT_DIR/.github/service-release-sources.json}"
REGISTRY_PATH=".github/service-release-sources.json"
POLLER="$ROOT_DIR/scripts/poll-service-releases.sh"

if (( $# != 2 )); then
  printf 'usage: %s BASE_REV HEAD_REV\n' "$0" >&2
  exit 2
fi
BASE_REV="$1"
HEAD_REV="$2"

for command_name in git python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'required command not found: %s\n' "$command_name" >&2
    exit 1
  }
done
[[ -f "$CONFIG_FILE" ]] || {
  printf 'service release config not found: %s\n' "$CONFIG_FILE" >&2
  exit 1
}
for rev in "$BASE_REV" "$HEAD_REV"; do
  git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || {
    printf 'revision not found: %s\n' "$rev" >&2
    exit 1
  }
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/select-service-validation.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# The registry as it was at each revision. A registry missing at the base
# (the file is being introduced) reads as empty, so every service counts as
# changed.
printf '{}\n' > "$work_dir/base-registry.json"
if git cat-file -e "$BASE_REV:$REGISTRY_PATH" 2>/dev/null; then
  git show "$BASE_REV:$REGISTRY_PATH" > "$work_dir/base-registry.json"
fi
git show "$HEAD_REV:$REGISTRY_PATH" > "$work_dir/head-registry.json"

git diff -z --name-only --no-renames "$BASE_REV" "$HEAD_REV" > "$work_dir/changed-paths"

selected_services="$(
  python3 - "$CONFIG_FILE" "$work_dir/base-registry.json" "$work_dir/head-registry.json" "$work_dir/changed-paths" <<'PY'
import json
import pathlib
import sys

config_file, base_file, head_file, paths_file = sys.argv[1:]
with open(paths_file, "rb") as fh:
    paths = [p for p in fh.read().decode("utf-8", "surrogateescape").split("\0") if p]


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


registry = list(load(config_file)["services"])
base = load(base_file)
head = load(head_file)

REGISTRY_FILE = ".github/service-release-sources.json"
ALL_WORKFLOWS = {
    ".github/workflows/service-release.yml",
    ".github/workflows/service-validation.yml",
}


def ignored_reason(path):
    parts = pathlib.PurePosixPath(path).parts
    name = parts[-1]
    if path in ALL_WORKFLOWS or path == REGISTRY_FILE:
        return None
    if name.endswith(".md"):
        return "documentation"
    if path in {"LICENSE", ".gitignore", ".gitattributes"}:
        return "repository metadata"
    if parts[0] == "docs":
        return "documentation"
    if (
        len(parts) == 2
        and parts[0] == "scripts"
        and ((name.startswith("test-") and name.endswith(".sh")) or name.endswith(".test.ts"))
    ):
        return "host unit test run by repository checks"
    if parts[0] == ".github":
        return "workflow or metadata that does not affect service builds"
    return None


def registry_changes():
    base_services = base.get("services") or {}
    head_services = head.get("services") or {}
    others_differ = {k: v for k, v in base.items() if k != "services"} != {
        k: v for k, v in head.items() if k != "services"
    }
    if others_differ:
        return None
    return [
        service
        for service in registry
        if service not in base_services or base_services[service] != head_services.get(service)
    ]


selected = set()
for path in paths:
    parts = pathlib.PurePosixPath(path).parts
    reason = ignored_reason(path)
    if reason:
        print(f"{path} -> ignored ({reason})", file=sys.stderr)
    elif len(parts) >= 3 and parts[0] == "services":
        if parts[1] in registry:
            selected.add(parts[1])
            print(f"{path} -> {parts[1]}", file=sys.stderr)
        else:
            print(f"{path} -> ignored (services/{parts[1]} is not a registered service)", file=sys.stderr)
    elif len(parts) >= 2 and parts[0] == "sources":
        if parts[1] in registry:
            selected.add(parts[1])
            print(f"{path} -> {parts[1]}", file=sys.stderr)
        else:
            selected.update(registry)
            print(f"{path} -> all services (source {parts[1]} is not a registered service)", file=sys.stderr)
    elif path == REGISTRY_FILE:
        changed = registry_changes()
        if changed is None:
            selected.update(registry)
            print(f"{path} -> all services (registry changed outside .services)", file=sys.stderr)
        else:
            selected.update(changed)
            names = " ".join(changed) if changed else "none"
            print(f"{path} -> services whose entry changed: {names}", file=sys.stderr)
    elif path in ALL_WORKFLOWS:
        selected.update(registry)
        print(f"{path} -> all services (shared release workflow)", file=sys.stderr)
    else:
        selected.update(registry)
        print(f"{path} -> all services (shared or unclassified path)", file=sys.stderr)

if not paths:
    print("no changed paths", file=sys.stderr)
ordered = [service for service in registry if service in selected]
print("selected services: " + (" ".join(ordered) if ordered else "none"), file=sys.stderr)
print(*ordered, sep="\n")
PY
)"

services=()
while IFS= read -r service; do
  if [[ -n "$service" ]]; then
    services+=("$service")
  fi
done <<< "$selected_services"

pairs=""
if (( ${#services[@]} > 0 )); then
  pairs="$("$POLLER" --validation-versions "${services[@]}")"
fi

PAIRS="$pairs" python3 - <<'PY'
import json
import os
import sys

include = []
for line in os.environ["PAIRS"].splitlines():
    if not line:
        continue
    service, version = line.split("\t")
    include.append({"service": service, "version": version})
summary = " ".join(f"{pair['service']}@{pair['version']}" for pair in include)
print(f"selected pairs: {summary or 'none'}", file=sys.stderr)
print(json.dumps({"include": include}, separators=(",", ":")))
PY
