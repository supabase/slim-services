#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/assert-revision-unpublished.sh RELEASE_TAG

Guard a job that pushes to a registry or bucket for RELEASE_TAG against an
already-published release. Revisions are immutable, so the bytes behind a
taken release must never be pushed to again. Queries the REST releases-by-tag
endpoint directly (it returns published releases only; drafts and missing
releases both 404), rather than "gh release view", whose combined REST and
GraphQL lookup can misreport a REST error on a published release as
"release not found":
  - the release does not exist (404): exit 0
  - the release is a draft (404, same as missing): exit 0
  - the release is published (200): exit 1 with a message
  - any other outcome: exit non-zero, so an API error is never read as
    "not published"
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 1 ]] || { usage >&2; exit 2; }

release_tag="$1"
: "${GH_REPO:?GH_REPO is required}"

set +e
output="$(gh api -i "repos/$GH_REPO/releases/tags/$release_tag" 2>&1)"
status=$?
set -e

if [[ $status -eq 0 ]]; then
  status_line="${output%%$'\n'*}"
  status_code="$(printf '%s\n' "$status_line" | awk '{print $2}')"
  if [[ "$status_code" == 2[0-9][0-9] ]]; then
    printf 'release %s is already published; revisions are immutable. Dispatch a new run (hotfix=true for a new revision).\n' "$release_tag" >&2
    exit 1
  fi
  printf 'unexpected gh api response for %s: %s\n' "$release_tag" "$status_line" >&2
  exit 1
fi

if [[ "$output" == *'(HTTP 404)'* ]]; then
  exit 0
fi

printf '%s\n' "$output" >&2
exit "$status"
