#!/usr/bin/env bash
set -euo pipefail

repository=""
confirmation=""
execute=0

usage() {
  cat <<'EOF'
Usage: scripts/purge-actions-retained-data.sh --repository OWNER/REPO [options]

Options:
  --execute                         Perform deletion; otherwise dry-run only.
  --confirm-delete-all OWNER/REPO  Required with --execute and must exactly
                                    match --repository.

Deletes every retained Actions workflow run and then any remaining standalone
Actions artifact. Deleting a workflow run also deletes its logs and artifacts.
The repository must still be INTERNAL or PRIVATE.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      repository="${2:?--repository requires OWNER/REPO}"
      shift 2
      ;;
    --execute)
      execute=1
      shift
      ;;
    --confirm-delete-all)
      confirmation="${2:?--confirm-delete-all requires OWNER/REPO}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$repository" ]] || {
  usage >&2
  exit 2
}
command -v gh >/dev/null || {
  echo "required command not found: gh" >&2
  exit 1
}

visibility="$(gh repo view "$repository" --json visibility --jq .visibility)"
if [[ "$visibility" == "PUBLIC" ]]; then
  echo "refusing to purge retained data after $repository is public" >&2
  exit 1
fi

runs="$(gh api "repos/$repository/actions/runs?per_page=1" --jq .total_count)"
artifacts="$(gh api "repos/$repository/actions/artifacts?per_page=1" --jq .total_count)"

echo "Repository:         $repository"
echo "Visibility:         $visibility"
echo "Workflow runs:      $runs"
echo "Workflow artifacts: $artifacts"

if [[ "$execute" != "1" ]]; then
  echo "Dry run only. Re-run with --execute --confirm-delete-all $repository to delete all retained Actions data."
  exit 0
fi

[[ "$confirmation" == "$repository" ]] || {
  echo "--confirm-delete-all must exactly match $repository" >&2
  exit 2
}

run_ids="$(mktemp "${TMPDIR:-/tmp}/slim-actions-runs.XXXXXX")"
artifact_ids="$(mktemp "${TMPDIR:-/tmp}/slim-actions-artifacts.XXXXXX")"
trap 'rm -f "$run_ids" "$artifact_ids"' EXIT

gh api --paginate "repos/$repository/actions/runs?per_page=100" \
  --jq '.workflow_runs[].id' > "$run_ids"
while IFS= read -r run_id; do
  [[ -n "$run_id" ]] || continue
  gh api --method DELETE "repos/$repository/actions/runs/$run_id" --silent
  echo "deleted workflow run $run_id"
done < "$run_ids"

gh api --paginate "repos/$repository/actions/artifacts?per_page=100" \
  --jq '.artifacts[].id' > "$artifact_ids"
while IFS= read -r artifact_id; do
  [[ -n "$artifact_id" ]] || continue
  gh api --method DELETE "repos/$repository/actions/artifacts/$artifact_id" --silent
  echo "deleted standalone artifact $artifact_id"
done < "$artifact_ids"

remaining_runs="$(gh api "repos/$repository/actions/runs?per_page=1" --jq .total_count)"
remaining_artifacts="$(gh api "repos/$repository/actions/artifacts?per_page=1" --jq .total_count)"
[[ "$remaining_runs" == "0" && "$remaining_artifacts" == "0" ]] || {
  echo "new Actions data appeared during cleanup; runs=$remaining_runs artifacts=$remaining_artifacts" >&2
  exit 1
}

echo "all retained Actions data deleted"
