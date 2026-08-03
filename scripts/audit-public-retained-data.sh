#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository=""
metadata_only=0

usage() {
  cat <<'EOF'
Usage: scripts/audit-public-retained-data.sh [--repository OWNER/REPO] [--metadata-only]

Inventory every repository surface that becomes visible during publication and
scan all published Git refs with Gitleaks. --metadata-only skips the secret scan
and is intended only for environments where Gitleaks is unavailable.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      repository="${2:?--repository requires OWNER/REPO}"
      shift 2
      ;;
    --metadata-only)
      metadata_only=1
      shift
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

for command in gh git jq; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

repository="${repository:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
visibility="$(gh repo view "$repository" --json visibility --jq .visibility)"
default_branch="$(gh repo view "$repository" --json defaultBranchRef --jq .defaultBranchRef.name)"

git -C "$ROOT_DIR" fetch origin --prune --quiet

remote_branches="$(git -C "$ROOT_DIR" for-each-ref refs/remotes/origin --format='%(refname:short)' | grep -v '^origin/HEAD$' | wc -l | tr -d ' ')"
unmerged_branches="$(git -C "$ROOT_DIR" branch -r --no-merged "origin/$default_branch" | sed 's/^ *//' | grep -v '^origin/HEAD' || true)"
unmerged_count="$(printf '%s\n' "$unmerged_branches" | sed '/^$/d' | wc -l | tr -d ' ')"
tags="$(git -C "$ROOT_DIR" tag --list | wc -l | tr -d ' ')"
commits="$(git -C "$ROOT_DIR" rev-list --count --remotes=origin --tags)"
author_emails="$(git -C "$ROOT_DIR" log --remotes=origin --tags --format='%ae' | sort -u | wc -l | tr -d ' ')"

runs="$(gh api "repos/$repository/actions/runs?per_page=1" --jq .total_count)"
artifacts="$(gh api "repos/$repository/actions/artifacts?per_page=1" --jq .total_count)"
pull_requests="$(gh pr list -R "$repository" --state all --limit 1000 --json number --jq length)"
issues="$(gh issue list -R "$repository" --state all --limit 1000 --json number --jq length)"
releases="$(gh release list -R "$repository" --limit 1000 --json tagName --jq length)"
open_secret_alerts="$(gh api "repos/$repository/secret-scanning/alerts?state=open&per_page=100" --jq length)"

read -r release_assets release_bytes < <(
  gh api --paginate "repos/$repository/releases?per_page=100" \
    --jq '.[] | [(.assets | length), ([.assets[].size] | add // 0)] | @tsv' \
    | awk '{ assets += $1; bytes += $2 } END { print assets + 0, bytes + 0 }'
)

cat <<EOF
Repository:              $repository
Visibility:              $visibility
Default branch:          $default_branch
Published commits:       $commits
Remote branches:         $remote_branches
Unmerged remote branches:$unmerged_count
Tags:                    $tags
Distinct author emails:  $author_emails
Pull requests:           $pull_requests
Issues:                  $issues
Workflow runs:           $runs
Workflow artifacts:      $artifacts
Releases:                $releases
Release assets:          $release_assets
Release asset bytes:     $release_bytes
Open secret alerts:      $open_secret_alerts
EOF

if [[ -n "$unmerged_branches" ]]; then
  echo
  echo "Unmerged remote branches requiring review:"
  printf '%s\n' "$unmerged_branches"
fi

if [[ "$metadata_only" == "1" ]]; then
  echo >&2
  echo "WARNING: published-ref secret scan skipped (--metadata-only)" >&2
  exit 0
fi

command -v gitleaks >/dev/null || {
  echo "gitleaks is required for the published-ref scan" >&2
  exit 1
}

echo
echo "Scanning all remote branches and tags with Gitleaks..."
gitleaks git "$ROOT_DIR" \
  --log-opts="--remotes=origin --tags" \
  --gitleaks-ignore-path "$ROOT_DIR/.gitleaksignore" \
  --redact --no-banner

[[ "$open_secret_alerts" == "0" ]] || {
  echo "repository has open GitHub secret-scanning alerts" >&2
  exit 1
}

echo "retained-data audit passed"
