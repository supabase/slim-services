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
  "release view postgres-${EXPECTED_VERSION}") exit 1 ;;
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
    FORCE=false \
    GH_TOKEN=test-token \
    GITHUB_OUTPUT="$github_output" \
    GITHUB_REPOSITORY_OWNER=supabase \
    GITHUB_WORKSPACE="$ROOT_DIR" \
    RUNNER_TEMP="$temp_dir/runner" \
    SERVICE=postgres \
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

for major in 15 17; do
  recipe_attr="$(
    VERSION="${major}.14.1.159" \
    SOURCE_REF="$source_commit" \
    bash -c '
      set -euo pipefail
      source services/postgres/recipe.env
      printf "%s\n" "$NIX_ATTR"
    '
  )"
  [[ "$recipe_attr" == "psql_${major}_cli_portable" ]] || {
    printf 'Postgres %s recipe selected the wrong portable Nix attribute: %s\n' \
      "$major" "$recipe_attr" >&2
    exit 1
  }
done

default_recipe_attr="$(
  env -u VERSION SOURCE_REF="$source_commit" bash -c '
    set -euo pipefail
    source services/postgres/recipe.env
    printf "%s\n" "$NIX_ATTR"
  '
)"
[[ "$default_recipe_attr" == "psql_17_cli_portable" ]] || {
  printf 'Postgres recipe parsed SOURCE_REF as a version when VERSION was unset: %s\n' \
    "$default_recipe_attr" >&2
  exit 1
}

unsupported_log="$temp_dir/unsupported-major.log"
if VERSION=16.14.1.159 SOURCE_REF="$source_commit" bash -c '
  set -euo pipefail
  source services/postgres/recipe.env
' >"$unsupported_log" 2>&1; then
  printf 'Postgres recipe accepted unsupported major 16\n' >&2
  exit 1
fi
grep -F 'unsupported Postgres major' "$unsupported_log" >/dev/null || {
  printf 'unsupported Postgres major failed for the wrong reason\n' >&2
  cat "$unsupported_log" >&2
  exit 1
}

printf 'Docker Hub release integration tests passed\n'
