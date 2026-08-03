#!/usr/bin/env bash
set -euo pipefail

repository=""
phase=""
apply=0
release_app_slug="${RELEASE_APP_SLUG:-supabase-cli-releaser}"

usage() {
  cat <<'EOF'
Usage: scripts/configure-public-repository.sh --repository OWNER/REPO --phase PHASE [--apply]

Phases:
  pre-public   Restrict Actions, require SHA pinning, and make the default
               workflow token read-only.
  post-public  Create or update the active main-branch ruleset after GitHub's
               visibility conversion has completed.

Without --apply the script prints the exact API requests and changes nothing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository)
      repository="${2:?--repository requires OWNER/REPO}"
      shift 2
      ;;
    --phase)
      phase="${2:?--phase requires pre-public or post-public}"
      shift 2
      ;;
    --apply)
      apply=1
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

[[ -n "$repository" && "$phase" =~ ^(pre-public|post-public)$ ]] || {
  usage >&2
  exit 2
}
for command in gh jq; do
  command -v "$command" >/dev/null || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

visibility="$(gh repo view "$repository" --json visibility --jq .visibility)"
default_branch="$(gh repo view "$repository" --json defaultBranchRef --jq .defaultBranchRef.name)"

apply_json() {
  local method="$1"
  local endpoint="$2"
  local payload="$3"
  if [[ "$apply" == "1" ]]; then
    printf '%s\n' "$payload" | gh api --method "$method" "$endpoint" --input - --silent
    echo "applied $method $endpoint"
  else
    echo "DRY RUN: $method $endpoint"
    printf '%s\n' "$payload" | jq .
  fi
}

apply_empty() {
  local method="$1"
  local endpoint="$2"
  if [[ "$apply" == "1" ]]; then
    gh api --method "$method" "$endpoint" --silent
    echo "applied $method $endpoint"
  else
    echo "DRY RUN: $method $endpoint"
  fi
}

if [[ "$phase" == "pre-public" ]]; then
  apply_json PUT "repos/$repository/actions/permissions" \
    '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}'
  apply_json PUT "repos/$repository/actions/permissions/selected-actions" \
    '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["docker/*","nixbuild/nix-quick-install-action@*","nix-community/cache-nix-action@*"]}'
  apply_json PUT "repos/$repository/actions/permissions/workflow" \
    '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
  exit 0
fi

if [[ "$apply" == "1" && "$visibility" != "PUBLIC" ]]; then
  echo "post-public settings cannot be applied while visibility is $visibility" >&2
  exit 1
fi

release_app_id="$(gh api "apps/$release_app_slug" --jq .id)"
ruleset_payload="$(jq -cn \
  --arg branch "$default_branch" \
  --argjson app_id "$release_app_id" \
  '{
    name: "public-main-protection",
    target: "branch",
    enforcement: "active",
    bypass_actors: [{actor_id: $app_id, actor_type: "Integration", bypass_mode: "always"}],
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "deletion"},
      {type: "non_fast_forward"},
      {type: "required_linear_history"},
      {type: "pull_request", parameters: {
        allowed_merge_methods: ["squash"],
        dismiss_stale_reviews_on_push: true,
        require_code_owner_review: false,
        require_last_push_approval: true,
        required_approving_review_count: 1,
        required_review_thread_resolution: true
      }},
      {type: "required_status_checks", parameters: {
        do_not_enforce_on_create: true,
        strict_required_status_checks_policy: true,
        required_status_checks: [{context: "public policy"}]
      }}
    ]
  }')"

ruleset_id="$(gh api "repos/$repository/rulesets" \
  --jq '.[] | select(.name == "public-main-protection") | .id' 2>/dev/null || true)"
if [[ -n "$ruleset_id" ]]; then
  apply_json PUT "repos/$repository/rulesets/$ruleset_id" "$ruleset_payload"
else
  apply_json POST "repos/$repository/rulesets" "$ruleset_payload"
fi
apply_empty PUT "repos/$repository/private-vulnerability-reporting"
