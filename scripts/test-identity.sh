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

if (
  SOURCE_IMAGE_DIGEST="sha256:99b1729aeb0bac314445024fc149fbd39306170b61dd50800ccf180327ab3459"
  IDENTITY_SOURCE_TAG=""
  UPSTREAM_IMAGE="supabase/postgres:17.6.1.158"
  pinned_upstream_ref
) >/dev/null 2>&1; then
  fail_test "pinned_upstream_ref accepted a missing IDENTITY_SOURCE_TAG"
fi
pass "missing IDENTITY_SOURCE_TAG is rejected"

SOURCE_IMAGE_DIGEST="sha256:99b1729aeb0bac314445024fc149fbd39306170b61dd50800ccf180327ab3459"
IDENTITY_SOURCE_TAG="17.6.1.158"
SOURCE_REF="17.6.1.166"
UPSTREAM_IMAGE="supabase/postgres:17.6.1.158"
ref="$(pinned_upstream_ref)"
[[ "$ref" == "supabase/postgres:17.6.1.158@sha256:99b1729aeb0bac314445024fc149fbd39306170b61dd50800ccf180327ab3459" ]] \
  || fail_test "unexpected pin ref: $ref"
pass "pin ref is tag@digest when the image tag matches IDENTITY_SOURCE_TAG"

# Release CI sets SOURCE_REF=VERSION. The committed digest must not be
# reused for a different tag (mock the inspect so this stays unit-local).
resolve_image_index_digest() {
  printf 'sha256:resolved-for-%s' "${1##*:}"
}
UPSTREAM_IMAGE="supabase/postgres:17.6.1.166"
ref="$(pinned_upstream_ref)"
[[ "$ref" == "supabase/postgres:17.6.1.166@sha256:resolved-for-17.6.1.166" ]] \
  || fail_test "CI VERSION must resolve its own digest, got: $ref"
pass "pin ref resolves a new digest when the image tag is not IDENTITY_SOURCE_TAG"
unset -f resolve_image_index_digest

# load_recipe must key UPSTREAM_IMAGE off VERSION, not the recipe SOURCE_REF.
resolve_image_index_digest() {
  printf 'sha256:resolved-for-%s' "${1##*:}"
}
for service in postgres storage edge-runtime; do
  recipe_version=""
  case "$service" in
    postgres) recipe_version="17.6.1.999" ;;
    storage) recipe_version="v9.9.9" ;;
    edge-runtime) recipe_version="v9.9.9" ;;
  esac
  unset SOURCE_IMAGE_DIGEST UPSTREAM_IMAGE SOURCE_REF VERSION IDENTITY_SOURCE_TAG SOURCE_IMAGE
  VERSION="$recipe_version"
  load_recipe "$service"
  [[ "$UPSTREAM_IMAGE" == *":$recipe_version" ]] \
    || fail_test "$service load_recipe under VERSION=$recipe_version set UPSTREAM_IMAGE=$UPSTREAM_IMAGE"
  ref="$(pinned_upstream_ref)"
  [[ "$ref" == *":$recipe_version@sha256:resolved-for-$recipe_version" ]] \
    || fail_test "$service pin under VERSION must resolve a new digest, got: $ref"
done
unset -f resolve_image_index_digest
unset SOURCE_IMAGE_DIGEST UPSTREAM_IMAGE SOURCE_REF VERSION IDENTITY_SOURCE_TAG SOURCE_IMAGE
pass "load_recipe pin follows VERSION, not IDENTITY_SOURCE_TAG"

# shellcheck source=scripts/identity-lib.sh
source "$ROOT_DIR/scripts/identity-lib.sh"
[[ "$(normalize_config_user "")" == "" ]] || fail_test "empty user should normalize to empty"
[[ "$(normalize_config_user 0)" == "" ]] || fail_test "USER 0 should normalize to empty"
[[ "$(normalize_config_user root)" == "" ]] || fail_test "USER root should normalize to empty"
[[ "$(normalize_config_user 100)" == "100" ]] || fail_test "non-root user must stay"
pass "start-user normalization"

if identity_service auth; then
  fail_test "auth should not be an identity service"
fi
pass "identity_service allow-list"

# Recipes pin a digest for the three identity services.
for service in postgres storage edge-runtime; do
  unset SOURCE_IMAGE_DIGEST UPSTREAM_IMAGE SOURCE_REF VERSION IDENTITY_SOURCE_TAG
  load_recipe "$service"
  [[ -n "${IDENTITY_SOURCE_TAG:-}" ]] || fail_test "$service recipe missing IDENTITY_SOURCE_TAG"
  [[ -n "${SOURCE_IMAGE_DIGEST:-}" ]] || fail_test "$service recipe missing SOURCE_IMAGE_DIGEST"
  case "$SOURCE_IMAGE_DIGEST" in
    sha256:*) ;;
    *) fail_test "$service SOURCE_IMAGE_DIGEST is not sha256: $SOURCE_IMAGE_DIGEST" ;;
  esac
  ref="$(pinned_upstream_ref)"
  [[ "$ref" == *"@$SOURCE_IMAGE_DIGEST" ]] || fail_test "$service pin ref $ref"
done
pass "recipe pins resolve"

# Static locks smokes cannot see. Image smokes cover argv, leftover I/O,
# migrate-call, and applet presence.
grep -Fq "ENTRYPOINT_JSON='[]'" "$ROOT_DIR/services/storage/recipe.env" \
  || fail_test "storage recipe must have an empty ENTRYPOINT"
grep -Fq "ENTRYPOINT_JSON='[]'" "$ROOT_DIR/services/auth/recipe.env" \
  || fail_test "auth recipe must have an empty ENTRYPOINT"
if grep -q 'chown' "$ROOT_DIR/scripts/render-dockerfile.sh"; then
  fail_test "render-dockerfile.sh rewrites chown; identity must use build-args"
fi
pass "empty ENTRYPOINT and append-only render"

# Fail-closed /mnt probe: stub docker so status 0/1/other is observable.
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-identity-probe.XXXXXX")"
SOURCE_IMAGE_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
UPSTREAM_IMAGE="example/storage:v1"
IDENTITY_SOURCE_TAG="v1"
pull_pinned_image() { return 0; }
image_config_user() { printf ''; }
pinned_upstream_ref() { printf 'example/storage:v1@%s' "$SOURCE_IMAGE_DIGEST"; }
run_in_pin() {
  shift
  case "$1" in
    stat) return 1 ;;
    test) return 2 ;;
    *) return 0 ;;
  esac
}
if ( write_upstream_identity storage "$probe_dir" ) >/dev/null 2>&1; then
  fail_test "test -e status 2 invented identity"
fi
pass "test -e probe failure fails closed"

run_in_pin() {
  shift
  case "$1" in
    stat) return 1 ;;
    test) return 0 ;;
    *) return 0 ;;
  esac
}
if ( write_upstream_identity storage "$probe_dir" ) >/dev/null 2>&1; then
  fail_test "exists-but-unstatable /mnt invented identity"
fi
pass "path exists but stat failed is fail-closed"

run_in_pin() {
  shift
  case "$1" in
    stat) return 1 ;;
    test) return 1 ;;
    *) return 0 ;;
  esac
}
write_upstream_identity storage "$probe_dir" >/dev/null \
  || fail_test "absent /mnt should invent 0:0:755"
# shellcheck source=/dev/null
source "$probe_dir/identity.env"
[[ "$VOLUME_UID" == "0" && "$VOLUME_GID" == "0" && "$VOLUME_MODE" == "755" ]] \
  || fail_test "absent /mnt invented $VOLUME_UID:$VOLUME_GID:$VOLUME_MODE"
pass "absent /mnt invents 0:0:755"
unset -f pull_pinned_image image_config_user pinned_upstream_ref run_in_pin
unset SOURCE_IMAGE_DIGEST UPSTREAM_IMAGE IDENTITY_SOURCE_TAG
rm -rf "$probe_dir"

printf 'test-identity: all passed\n'
