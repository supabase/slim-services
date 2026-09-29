#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/assert-revision-unpublished.sh RELEASE_TAG

Guard a job that pushes to a registry or bucket for RELEASE_TAG against an
already-published release. Revisions are immutable, so the bytes behind a
taken release must never be pushed to again:
  - the release does not exist: exit 0
  - the release exists as a draft (uncommitted scratch, not taken): exit 0
  - the release is published: exit 1 with a message
  - any other gh failure: exit non-zero, so an API error is never read as
    "not published"
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

release_tag="$1"

set +e
output="$(gh release view "$release_tag" --json isDraft 2>&1)"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  if [[ "$output" == *"release not found"* ]]; then
    exit 0
  fi
  printf '%s\n' "$output" >&2
  exit "$status"
fi

is_draft="$(python3 -c 'import json,sys; print(str(json.loads(sys.argv[1])["isDraft"]).lower())' "$output")"
if [[ "$is_draft" == "true" ]]; then
  exit 0
fi

printf 'release %s is already published; revisions are immutable. Dispatch a new run (hotfix=true for a new revision).\n' "$release_tag" >&2
exit 1
