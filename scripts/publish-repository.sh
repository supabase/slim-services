#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository=""
confirmation=""
execute=0

usage() {
  cat <<'EOF'
Usage: scripts/publish-repository.sh --repository OWNER/REPO [options]

Options:
  --execute                       Perform the visibility change.
  --confirm-public OWNER/REPO    Required with --execute and must exactly
                                  match --repository.

Execution also requires these human approval environment variables to equal 1:
  LEGAL_REVIEW_APPROVED
  RELEASE_ASSETS_APPROVED
  PUBLICATION_CONTENT_REVIEW_APPROVED
  RUNNER_POLICY_APPROVED
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
    --confirm-public)
      confirmation="${2:?--confirm-public requires OWNER/REPO}"
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
echo "Repository: $repository"
echo "Current visibility: $visibility"

if [[ "$execute" != "1" ]]; then
  cat <<EOF
Dry run only. Execution will:
  1. apply pre-public Actions restrictions
  2. run the complete pre-public verification gate
  3. change $repository visibility to public
  4. apply the post-public ruleset and vulnerability-reporting settings
  5. run the complete post-public verification gate
EOF
  exit 0
fi

[[ "$confirmation" == "$repository" ]] || {
  echo "--confirm-public must exactly match $repository" >&2
  exit 2
}
[[ "$visibility" != "PUBLIC" ]] || {
  echo "$repository is already public" >&2
  exit 1
}

approvals=(
  LEGAL_REVIEW_APPROVED
  RELEASE_ASSETS_APPROVED
  PUBLICATION_CONTENT_REVIEW_APPROVED
  RUNNER_POLICY_APPROVED
)
for approval in "${approvals[@]}"; do
  [[ "${!approval:-}" == "1" ]] || {
    echo "required human approval is missing: $approval=1" >&2
    exit 1
  }
done

"$ROOT_DIR/scripts/configure-public-repository.sh" \
  --repository "$repository" --phase pre-public --apply
"$ROOT_DIR/scripts/verify-public-readiness.sh" \
  --repository "$repository" --phase pre-public

gh repo edit "$repository" \
  --visibility public \
  --accept-visibility-change-consequences

for _ in {1..12}; do
  [[ "$(gh repo view "$repository" --json visibility --jq .visibility)" == "PUBLIC" ]] && break
  sleep 5
done
[[ "$(gh repo view "$repository" --json visibility --jq .visibility)" == "PUBLIC" ]] || {
  echo "visibility change did not converge to PUBLIC within 60 seconds" >&2
  exit 1
}

"$ROOT_DIR/scripts/configure-public-repository.sh" \
  --repository "$repository" --phase post-public --apply
"$ROOT_DIR/scripts/verify-public-readiness.sh" \
  --repository "$repository" --phase post-public

echo "$repository is public and all post-public gates passed"
