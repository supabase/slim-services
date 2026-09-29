#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="$ROOT_DIR/scripts/resolve-dockerhub-release.sh"

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

fake_bin="$temp_dir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/curl" <<'SH'
#!/bin/sh
set -eu
expected_url="${DOCKER_HUB_API_BASE}/repositories/${EXPECTED_IMAGE_REPOSITORY}/tags/${EXPECTED_VERSION}"
[ "$*" = "-fsSL $expected_url" ] || {
  printf 'unexpected curl invocation: %s\n' "$*" >&2
  exit 2
}
printf '{"name":"%s","images":[{"architecture":"amd64","os":"linux"},{"architecture":"arm64","os":"linux"}]}\n' \
  "$DOCKER_HUB_RESPONSE_TAG"
SH

cat > "$fake_bin/docker" <<'SH'
#!/bin/sh
set -eu
expected="buildx imagetools inspect ${EXPECTED_IMAGE_REPOSITORY}:${EXPECTED_VERSION} --format {{json .Provenance}}"
[ "$*" = "$expected" ] || {
  printf 'unexpected docker invocation: %s\n' "$*" >&2
  exit 2
}
printf '%s\n' "$DOCKER_PROVENANCE"
SH

cat > "$fake_bin/gh" <<'SH'
#!/bin/sh
set -eu
case "$*" in
  "api repos/${EXPECTED_SOURCE_REPOSITORY}/commits/${EXPECTED_SOURCE_COMMIT} --silent") ;;
  "api --paginate repos/${GH_REPO}/releases?per_page=100 --jq .[] | select(.draft | not) | .tag_name")
    [ -z "${FAKE_RELEASE_TAGS:-}" ] || printf '%s\n' "$FAKE_RELEASE_TAGS"
    ;;
  *)
    printf 'unexpected gh invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH

chmod +x "$fake_bin/curl" "$fake_bin/docker" "$fake_bin/gh"

source_commit="1c15f4b84427a666c7b8ad2fce0d09bd5f01ceb4"
base_environment=(
  "PATH=$fake_bin:$PATH"
  "DOCKER_HUB_API_BASE=https://registry.example.test/v2"
  "EXPECTED_SOURCE_REPOSITORY=supabase/postgres"
  "EXPECTED_SOURCE_COMMIT=$source_commit"
)

postgres_output="$(
  env \
    "${base_environment[@]}" \
    EXPECTED_IMAGE_REPOSITORY=supabase/postgres \
    EXPECTED_VERSION=17.6.1.163 \
    DOCKER_HUB_RESPONSE_TAG=17.6.1.163 \
    DOCKER_PROVENANCE="{\"linux/amd64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}},\"linux/arm64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}}}" \
    "$RESOLVER" \
      supabase/postgres \
      17.6.1.163 \
      supabase/postgres
)"
[[ "$postgres_output" == "$source_commit" ]] || {
  printf 'unexpected Postgres source commit: %s\n' "$postgres_output" >&2
  exit 1
}

studio_commit="022b374d9fd6f2608a1a03fb942872125f17a866"
studio_output="$(
  env \
    "${base_environment[@]}" \
    EXPECTED_IMAGE_REPOSITORY=supabase/studio \
    EXPECTED_SOURCE_REPOSITORY=supabase/supabase \
    EXPECTED_SOURCE_COMMIT="$studio_commit" \
    EXPECTED_VERSION=2026.08.03-sha-022b374 \
    DOCKER_HUB_RESPONSE_TAG=2026.08.03-sha-022b374 \
    DOCKER_PROVENANCE="{\"linux/amd64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$studio_commit\"}}}}}}" \
    "$RESOLVER" \
      supabase/studio \
      2026.08.03-sha-022b374 \
      supabase/supabase \
      '-sha-([0-9a-f]{7})$'
)"
[[ "$studio_output" == "$studio_commit" ]] || {
  printf 'unexpected Studio source commit: %s\n' "$studio_output" >&2
  exit 1
}

mismatch_log="$temp_dir/mismatch.log"
if env \
  "${base_environment[@]}" \
  EXPECTED_IMAGE_REPOSITORY=supabase/studio \
  EXPECTED_SOURCE_REPOSITORY=supabase/supabase \
  EXPECTED_SOURCE_COMMIT="$studio_commit" \
  EXPECTED_VERSION=2026.08.03-sha-deadbee \
  DOCKER_HUB_RESPONSE_TAG=2026.08.03-sha-deadbee \
  DOCKER_PROVENANCE="{\"linux/amd64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$studio_commit\"}}}}}}" \
  "$RESOLVER" \
    supabase/studio \
    2026.08.03-sha-deadbee \
    supabase/supabase \
    '-sha-([0-9a-f]{7})$' >"$mismatch_log" 2>&1; then
  printf 'accepted a Docker tag whose embedded source ref disagrees with provenance\n' >&2
  exit 1
fi
grep -F 'Docker tag source ref deadbee disagrees with provenance' "$mismatch_log" >/dev/null || {
  printf 'Studio provenance mismatch failed for the wrong reason\n' >&2
  cat "$mismatch_log" >&2
  exit 1
}

plan_run="$(ruby -ryaml -e '
data = YAML.safe_load(File.read(ARGV[0]), aliases: true)
step = data.fetch("jobs").fetch("plan").fetch("steps").find do |item|
  item["name"] == "Validate inputs and check existing release"
end
puts step.fetch("run")
' "$ROOT_DIR/.github/workflows/service-release.yml")"
github_output="$temp_dir/github-output"
touch "$github_output"
(
  cd "$ROOT_DIR"
  env \
    "${base_environment[@]}" \
    EXPECTED_IMAGE_REPOSITORY=supabase/postgres \
    EXPECTED_VERSION=17.6.1.163 \
    DOCKER_HUB_RESPONSE_TAG=17.6.1.163 \
    DOCKER_PROVENANCE="{\"linux/amd64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}},\"linux/arm64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}}}" \
    GH_REPO=supabase/slim-services \
    GH_TOKEN=test-token \
    GITHUB_OUTPUT="$github_output" \
    GITHUB_REF=refs/heads/main \
    GITHUB_REPOSITORY_OWNER=supabase \
    GITHUB_WORKSPACE="$ROOT_DIR" \
    HOTFIX=false \
    RUNNER_TEMP="$temp_dir/runner" \
    SERVICE=postgres \
    VALIDATION_ONLY=false \
    VERSION=17.6.1.163 \
    bash -c "$plan_run"
)

grep -Fx "source_ref=$source_commit" "$github_output" >/dev/null || {
  printf 'release plan did not export the Postgres image provenance commit\n' >&2
  exit 1
}
grep -Fx 'upstream_image_repository=supabase/postgres' "$github_output" >/dev/null || {
  printf 'release plan did not export the Postgres Docker image repository\n' >&2
  exit 1
}

blank_hotfix_reason_log="$temp_dir/blank-hotfix-reason.log"
if env \
  "${base_environment[@]}" \
  EXPECTED_IMAGE_REPOSITORY=supabase/postgres \
  EXPECTED_VERSION=17.6.1.163 \
  DOCKER_HUB_RESPONSE_TAG=17.6.1.163 \
  DOCKER_PROVENANCE="{\"linux/amd64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}},\"linux/arm64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}}}" \
  GH_REPO=supabase/slim-services \
  GH_TOKEN=test-token \
  GITHUB_OUTPUT="$temp_dir/blank-hotfix-reason-output" \
  GITHUB_REF=refs/heads/main \
  GITHUB_REPOSITORY_OWNER=supabase \
  GITHUB_WORKSPACE="$ROOT_DIR" \
  HOTFIX=true \
  HOTFIX_REASON="$(printf '\t\n\t')" \
  RUNNER_TEMP="$temp_dir/runner-blank-hotfix-reason" \
  SERVICE=postgres \
  VALIDATION_ONLY=false \
  VERSION=17.6.1.163 \
  bash -c "$plan_run" >"$blank_hotfix_reason_log" 2>&1; then
  printf 'plan accepted a hotfix reason made only of tabs and newlines\n' >&2
  cat "$blank_hotfix_reason_log" >&2
  exit 1
fi
grep -F 'hotfix_reason is required when hotfix is true' "$blank_hotfix_reason_log" >/dev/null || {
  printf 'blank hotfix reason failed for the wrong reason\n' >&2
  cat "$blank_hotfix_reason_log" >&2
  exit 1
}

valid_hotfix_reason_output="$temp_dir/valid-hotfix-reason-output"
(
  cd "$ROOT_DIR"
  env \
    "${base_environment[@]}" \
    EXPECTED_IMAGE_REPOSITORY=supabase/postgres \
    EXPECTED_VERSION=17.6.1.163 \
    DOCKER_HUB_RESPONSE_TAG=17.6.1.163 \
    DOCKER_PROVENANCE="{\"linux/amd64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}},\"linux/arm64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}}}" \
    GH_REPO=supabase/slim-services \
    GH_TOKEN=test-token \
    GITHUB_OUTPUT="$valid_hotfix_reason_output" \
    GITHUB_REF=refs/heads/main \
    GITHUB_REPOSITORY_OWNER=supabase \
    GITHUB_WORKSPACE="$ROOT_DIR" \
    FAKE_RELEASE_TAGS='postgres-17.6.1.163-r0' \
    HOTFIX=true \
    HOTFIX_REASON='fix a broken image tag' \
    RUNNER_TEMP="$temp_dir/runner-valid-hotfix-reason" \
    SERVICE=postgres \
    VALIDATION_ONLY=false \
    VERSION=17.6.1.163 \
    bash -c "$plan_run"
)
grep -Fx "source_ref=$source_commit" "$valid_hotfix_reason_output" >/dev/null || {
  printf 'plan rejected a non-blank hotfix reason\n' >&2
  exit 1
}

# The token check lives in its own step, run once after both the external
# and non-external plan branches, gated on publish == true.
token_check_run="$(ruby -ryaml -e '
data = YAML.safe_load(File.read(ARGV[0]), aliases: true)
step = data.fetch("jobs").fetch("plan").fetch("steps").find do |item|
  item["name"] == "Require the CLI notification token when publishing"
end
puts step.fetch("run")
' "$ROOT_DIR/.github/workflows/service-release.yml")"

missing_token_log="$temp_dir/missing-token.log"
missing_token_output="$temp_dir/missing-token-output"
if (
  cd "$ROOT_DIR"
  env \
    "${base_environment[@]}" \
    EXPECTED_IMAGE_REPOSITORY=supabase/postgres \
    EXPECTED_VERSION=17.6.1.163 \
    DOCKER_HUB_RESPONSE_TAG=17.6.1.163 \
    DOCKER_PROVENANCE="{\"linux/amd64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}},\"linux/arm64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}}}" \
    GH_REPO=supabase/slim-services \
    GH_TOKEN=test-token \
    GITHUB_OUTPUT="$missing_token_output" \
    GITHUB_REF=refs/heads/main \
    GITHUB_REPOSITORY_OWNER=supabase \
    GITHUB_WORKSPACE="$ROOT_DIR" \
    HOTFIX=false \
    RUNNER_TEMP="$temp_dir/runner-missing-token" \
    SERVICE=postgres \
    VALIDATION_ONLY=false \
    VERSION=17.6.1.163 \
    bash -c "$plan_run" &&
  grep -Fxq 'publish=true' "$missing_token_output" &&
  env NOTIFY_TOKEN_PRESENT=false bash -c "$token_check_run"
) >"$missing_token_log" 2>&1; then
  printf 'plan published without the CLI dispatch token configured\n' >&2
  cat "$missing_token_log" >&2
  exit 1
fi
grep -F 'CLI_MIRROR_DISPATCH_TOKEN is not configured' "$missing_token_log" >/dev/null || {
  printf 'plan failed for the wrong reason with a missing dispatch token\n' >&2
  cat "$missing_token_log" >&2
  exit 1
}

validation_only_log="$temp_dir/validation-only-missing-token.log"
validation_only_output="$temp_dir/validation-only-missing-token-output"
if ! (
  cd "$ROOT_DIR"
  env \
    "${base_environment[@]}" \
    EXPECTED_IMAGE_REPOSITORY=supabase/postgres \
    EXPECTED_VERSION=17.6.1.163 \
    DOCKER_HUB_RESPONSE_TAG=17.6.1.163 \
    DOCKER_PROVENANCE="{\"linux/amd64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}},\"linux/arm64\":{\"SLSA\":{\"invocation\":{\"configSource\":{\"digest\":{\"sha1\":\"$source_commit\"}}}}}}" \
    GH_REPO=supabase/slim-services \
    GH_TOKEN=test-token \
    GITHUB_OUTPUT="$validation_only_output" \
    GITHUB_REF=refs/heads/main \
    GITHUB_REPOSITORY_OWNER=supabase \
    GITHUB_WORKSPACE="$ROOT_DIR" \
    HOTFIX=false \
    RUNNER_TEMP="$temp_dir/runner-validation-only" \
    SERVICE=postgres \
    VALIDATION_ONLY=true \
    VERSION=17.6.1.163 \
    bash -c "$plan_run"
) >"$validation_only_log" 2>&1; then
  printf 'plan step failed for validation_only with no dispatch token configured\n' >&2
  cat "$validation_only_log" >&2
  exit 1
fi
grep -Fxq 'publish=false' "$validation_only_output" || {
  printf 'validation_only run unexpectedly planned to publish: %s\n' "$(cat "$validation_only_output")" >&2
  exit 1
}

postgres_recipe_image="$(
  VERSION=17.6.1.163 \
  SOURCE_REF="$source_commit" \
  bash -c '
    set -euo pipefail
    source services/postgres/recipe.env
    printf "%s\n" "$UPSTREAM_IMAGE"
  '
)"
[[ "$postgres_recipe_image" == 'supabase/postgres:17.6.1.163' ]] || {
  printf 'Postgres recipe coupled the comparison image to its source commit: %s\n' \
    "$postgres_recipe_image" >&2
  exit 1
}

printf 'Docker Hub release integration tests passed\n'
