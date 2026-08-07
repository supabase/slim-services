#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository=""
phase="code"
max_runs="${PUBLICATION_MAX_RETAINED_RUNS:-5}"
max_artifacts="${PUBLICATION_MAX_RETAINED_ARTIFACTS:-0}"

usage() {
  cat <<'EOF'
Usage: scripts/verify-public-readiness.sh [options]

Options:
  --repository OWNER/REPO
  --phase code|pre-public|post-public
  --max-retained-runs N
  --max-retained-artifacts N

The code phase is local-only. Pre-public and post-public also verify live
repository settings, retained data, releases, secret alerts, and rulesets.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      repository="${2:?--repository requires OWNER/REPO}"
      shift 2
      ;;
    --phase)
      phase="${2:?--phase requires a value}"
      shift 2
      ;;
    --max-retained-runs)
      max_runs="${2:?--max-retained-runs requires a number}"
      shift 2
      ;;
    --max-retained-artifacts)
      max_artifacts="${2:?--max-retained-artifacts requires a number}"
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

[[ "$phase" =~ ^(code|pre-public|post-public)$ ]] || {
  usage >&2
  exit 2
}
[[ "$max_runs" =~ ^[0-9]+$ && "$max_artifacts" =~ ^[0-9]+$ ]] || {
  echo "retained-data limits must be non-negative integers" >&2
  exit 2
}

required_files=(
  LICENSE
  THIRD_PARTY_NOTICES.md
  SECURITY.md
  .gitleaksignore
  scripts/audit-public-retained-data.sh
  scripts/check-actions-pinned.sh
  scripts/configure-public-repository.sh
  scripts/generate-artifact-sbom.py
  scripts/purge-actions-retained-data.sh
  scripts/test-actions-pinned.sh
  scripts/test-license-compliance.sh
  scripts/test-publish-repository.sh
  scripts/test-upstream-runtime.sh
)
for path in "${required_files[@]}"; do
  [[ -f "$ROOT_DIR/$path" ]] || {
    echo "required public-release file is missing: $path" >&2
    exit 1
  }
done

"$ROOT_DIR/scripts/check-actions-pinned.sh"
"$ROOT_DIR/scripts/test-actions-pinned.sh"
"$ROOT_DIR/scripts/test-license-compliance.sh"
"$ROOT_DIR/scripts/test-upstream-runtime.sh"

command -v gitleaks >/dev/null || {
  echo "gitleaks is required for the public-readiness gate" >&2
  exit 1
}
if [[ "$phase" != "code" ]]; then
  git -C "$ROOT_DIR" fetch origin --prune --quiet
fi
gitleaks git "$ROOT_DIR" \
  --log-opts="--remotes=origin --tags" \
  --gitleaks-ignore-path "$ROOT_DIR/.gitleaksignore" \
  --redact --no-banner

if [[ "$phase" == "code" ]]; then
  echo "public-readiness code gate passed"
  exit 0
fi

[[ -n "$repository" ]] || {
  echo "--repository is required for $phase" >&2
  exit 2
}
for command in gh jq; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

visibility="$(gh repo view "$repository" --json visibility --jq .visibility)"
if [[ "$phase" == "pre-public" && "$visibility" == "PUBLIC" ]]; then
  echo "expected an internal/private repository before publication" >&2
  exit 1
fi
if [[ "$phase" == "post-public" && "$visibility" != "PUBLIC" ]]; then
  echo "expected PUBLIC visibility after publication, got $visibility" >&2
  exit 1
fi

actions_permissions="$(gh api "repos/$repository/actions/permissions")"
[[ "$(jq -r .allowed_actions <<< "$actions_permissions")" == "selected" ]]
[[ "$(jq -r .sha_pinning_required <<< "$actions_permissions")" == "true" ]]

workflow_permissions="$(gh api "repos/$repository/actions/permissions/workflow")"
[[ "$(jq -r .default_workflow_permissions <<< "$workflow_permissions")" == "read" ]]
[[ "$(jq -r .can_approve_pull_request_reviews <<< "$workflow_permissions")" == "false" ]]

selected_actions="$(gh api "repos/$repository/actions/permissions/selected-actions")"
[[ "$(jq -r .github_owned_allowed <<< "$selected_actions")" == "true" ]]
[[ "$(jq -r .verified_allowed <<< "$selected_actions")" == "false" ]]
expected_action_patterns='["docker/*","nixbuild/nix-quick-install-action@*","nix-community/cache-nix-action@*"]'
[[ "$(jq -c '.patterns_allowed | sort' <<< "$selected_actions")" == \
   "$(jq -c 'sort' <<< "$expected_action_patterns")" ]]

open_secret_alerts="$(gh api "repos/$repository/secret-scanning/alerts?state=open&per_page=100" --jq length)"
[[ "$open_secret_alerts" == "0" ]] || {
  echo "open GitHub secret-scanning alerts: $open_secret_alerts" >&2
  exit 1
}

runs="$(gh api "repos/$repository/actions/runs?per_page=1" --jq .total_count)"
artifacts="$(gh api "repos/$repository/actions/artifacts?per_page=1" --jq .total_count)"
(( runs <= max_runs )) || {
  echo "retained workflow runs exceed limit: $runs > $max_runs" >&2
  exit 1
}
(( artifacts <= max_artifacts )) || {
  echo "retained workflow artifacts exceed limit: $artifacts > $max_artifacts" >&2
  exit 1
}

default_branch="$(gh repo view "$repository" --json defaultBranchRef --jq .defaultBranchRef.name)"
unmerged="$(git -C "$ROOT_DIR" branch -r --no-merged "origin/$default_branch" \
  | sed 's/^ *//' | grep -Ev '^origin/(HEAD|agent/public-gate-4-cutover)$' || true)"
[[ -z "$unmerged" ]] || {
  echo "unmerged remote branches still require review:" >&2
  printf '%s\n' "$unmerged" >&2
  exit 1
}

bad_releases="$(gh api --paginate "repos/$repository/releases?per_page=100" \
  --jq '.[] | {tag: .tag_name, sboms: ([.assets[].name | select(endswith(".sbom.spdx.json"))] | length)} | select(.sboms != 3) | [.tag, (.sboms | tostring)] | @tsv')"
[[ -z "$bad_releases" ]] || {
  echo "releases without exactly three target SBOMs:" >&2
  printf '%s\n' "$bad_releases" >&2
  exit 1
}

if [[ "$phase" == "post-public" ]]; then
  ruleset_id="$(gh api "repos/$repository/rulesets" \
    --jq '.[] | select(.name == "public-main-protection") | .id')"
  [[ -n "$ruleset_id" ]] || {
    echo "active public-main-protection ruleset not found" >&2
    exit 1
  }
  ruleset="$(gh api "repos/$repository/rulesets/$ruleset_id")"
  [[ "$(jq -r .enforcement <<< "$ruleset")" == "active" ]]
  for rule in deletion non_fast_forward required_linear_history pull_request required_status_checks; do
    jq -e --arg rule "$rule" '.rules | any(.type == $rule)' <<< "$ruleset" >/dev/null || {
      echo "public-main-protection is missing rule: $rule" >&2
      exit 1
    }
  done
  jq -e '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks | any(.context == "public policy")' \
    <<< "$ruleset" >/dev/null || {
    echo "public-main-protection does not require the public policy check" >&2
    exit 1
  }
  vulnerability_reporting="$(gh api "repos/$repository/private-vulnerability-reporting" --jq .enabled)"
  [[ "$vulnerability_reporting" == "true" ]] || {
    echo "private vulnerability reporting is not enabled" >&2
    exit 1
  }
fi

echo "public-readiness $phase gate passed"
