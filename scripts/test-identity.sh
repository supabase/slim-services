#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok: %s\n' "$*"
}

# pinned_upstream_ref requires a digest and rejects a floating tag.
# fail() exits; run the helper in a subshell so a rejected pin is observable.
if (
  SOURCE_IMAGE_DIGEST=""
  UPSTREAM_IMAGE="supabase/postgres:17.6.1.158"
  pinned_upstream_ref
) >/dev/null 2>&1; then
  fail_test "pinned_upstream_ref accepted a missing digest"
fi
pass "missing digest is rejected"

if (
  SOURCE_IMAGE_DIGEST="not-a-digest"
  UPSTREAM_IMAGE="supabase/postgres:17.6.1.158"
  pinned_upstream_ref
) >/dev/null 2>&1; then
  fail_test "pinned_upstream_ref accepted a non-sha256 digest"
fi
pass "non-sha256 digest is rejected"

SOURCE_IMAGE_DIGEST="sha256:99b1729aeb0bac314445024fc149fbd39306170b61dd50800ccf180327ab3459"
SOURCE_REF="17.6.1.158"
UPSTREAM_IMAGE="supabase/postgres:17.6.1.158"
ref="$(pinned_upstream_ref)"
[[ "$ref" == "supabase/postgres:17.6.1.158@sha256:99b1729aeb0bac314445024fc149fbd39306170b61dd50800ccf180327ab3459" ]] \
  || fail_test "unexpected pin ref: $ref"
pass "pin ref is tag@digest for the recipe SOURCE_REF"

# shellcheck source=scripts/identity-lib.sh
source "$ROOT_DIR/scripts/identity-lib.sh"
[[ "$(normalize_config_user "")" == "" ]] || fail_test "empty user should normalize to empty"
[[ "$(normalize_config_user 0)" == "" ]] || fail_test "USER 0 should normalize to empty"
[[ "$(normalize_config_user root)" == "" ]] || fail_test "USER root should normalize to empty"
[[ "$(normalize_config_user 100)" == "100" ]] || fail_test "non-root user must stay"
pass "start-user normalization"

identity_service postgres || fail_test "postgres should be an identity service"
identity_service storage || fail_test "storage should be an identity service"
identity_service edge-runtime || fail_test "edge-runtime should be an identity service"
if identity_service auth; then
  fail_test "auth should not be an identity service"
fi
pass "identity_service allow-list"

# Recipes pin a digest for the three identity services.
for service in postgres storage edge-runtime; do
  unset SOURCE_IMAGE_DIGEST UPSTREAM_IMAGE SOURCE_REF VERSION
  load_recipe "$service"
  [[ -n "${SOURCE_IMAGE_DIGEST:-}" ]] || fail_test "$service recipe missing SOURCE_IMAGE_DIGEST"
  case "$SOURCE_IMAGE_DIGEST" in
    sha256:*) ;;
    *) fail_test "$service SOURCE_IMAGE_DIGEST is not sha256: $SOURCE_IMAGE_DIGEST" ;;
  esac
  ref="$(pinned_upstream_ref)"
  [[ "$ref" == *"@$SOURCE_IMAGE_DIGEST" ]] || fail_test "$service pin ref $ref"
done
pass "recipe pins resolve"

grep -q 'SOURCE_IMAGE_DIGEST' "$ROOT_DIR/IMAGE_CONTRACT.md" \
  || fail_test "IMAGE_CONTRACT.md does not describe SOURCE_IMAGE_DIGEST"
grep -q 'cannot build' "$ROOT_DIR/scripts/build-image-from-artifact.sh" \
  || fail_test "image build must refuse SKIP_UPSTREAM_IDENTITY"
pass "contract docs; SKIP cannot invent identity"

# render-dockerfile.sh must stay append-only (no mid-file --chown rewrite).
if grep -q 'chown' "$ROOT_DIR/scripts/render-dockerfile.sh"; then
  fail_test "render-dockerfile.sh rewrites chown; identity must use build-args"
fi
pass "render-dockerfile.sh stays append-only"

quoted_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-identity-quote.XXXXXX")"
trap 'rm -rf "$quoted_dir"' EXIT
# Simulate the writer: values go through %q so a GECOS space cannot break source.
printf 'DROP_TO_NAME=%q\n' "PostgreSQL administrator" >"$quoted_dir/identity.env"
# shellcheck source=/dev/null
source "$quoted_dir/identity.env"
[[ "$DROP_TO_NAME" == "PostgreSQL administrator" ]] \
  || fail_test "quoted identity.env did not round-trip a spaced name"
pass "identity.env quoting survives GECOS spaces"

printf 'test-identity: all passed\n'
