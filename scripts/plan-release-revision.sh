#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/plan-release-revision.sh SERVICE UPSTREAM_VERSION VALIDATION_ONLY HOTFIX GIT_REF

Allocate the next immutable release revision N for SERVICE at UPSTREAM_VERSION
and decide whether this run should build and publish. The full paginated
GitHub release list for GH_REPO is read to determine which revisions of
SERVICE-UPSTREAM_VERSION are already taken (released as SERVICE-UPSTREAM_VERSION-rN).
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 5 ]] || { usage >&2; exit 2; }

service="$1"
upstream_version="$2"
validation_only="$3"
hotfix="$4"
git_ref="$5"

for value in "$validation_only" "$hotfix"; do
  case "$value" in
    true|false) ;;
    *) usage >&2; exit 2 ;;
  esac
done

python3 - "$service" "$upstream_version" "$validation_only" "$hotfix" "$git_ref" <<'PY'
import json
import os
import re
import subprocess
import sys

service = sys.argv[1]
upstream_version = sys.argv[2]
validation_only = sys.argv[3] == "true"
hotfix = sys.argv[4] == "true"
git_ref = sys.argv[5]

if hotfix and validation_only:
    raise SystemExit("hotfix and validation_only are exclusive")

repo = os.environ.get("GH_REPO")
if not repo:
    raise SystemExit("GH_REPO is required")

try:
    result = subprocess.run(
        [
            "gh",
            "api",
            "--paginate",
            f"repos/{repo}/releases?per_page=100",
            "--jq",
            ".[] | select(.draft | not) | .tag_name",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
except subprocess.CalledProcessError as error:
    raise SystemExit(error.stderr.strip() or "could not list releases") from error

pattern = re.compile(rf"^{re.escape(service)}-{re.escape(upstream_version)}-r(0|[1-9][0-9]*)$")
taken = sorted(
    int(match.group(1))
    for match in (pattern.match(tag) for tag in result.stdout.splitlines())
    if match
)

if hotfix and not taken:
    raise SystemExit(f"no published revision of {service} {upstream_version} to hotfix")

if validation_only:
    build, publish = True, False
    revision = taken[-1] + 1 if taken else 0
elif hotfix:
    build, publish = True, True
    revision = taken[-1] + 1
elif not taken:
    build, publish = True, True
    revision = 0
else:
    build, publish = False, False
    revision = taken[-1]

release_version = f"{upstream_version}-r{revision}"
release_tag = f"{service}-{release_version}"

if publish and git_ref != "refs/heads/main":
    raise SystemExit(f"publishing requires refs/heads/main; use validation_only on {git_ref}")

if not build and not publish:
    print(f"{service} {upstream_version} already published as {release_tag}", file=sys.stderr)

print(
    json.dumps(
        {
            "build": build,
            "publish": publish,
            "revision": revision,
            "release_version": release_version,
            "release_tag": release_tag,
            "taken": taken,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
)
PY
