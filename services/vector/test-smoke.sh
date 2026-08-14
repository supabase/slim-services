#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

smoke="$ROOT_DIR/services/vector/smoke.sh"
recipe="$ROOT_DIR/services/vector/recipe.env"
runtime="$ROOT_DIR/services/vector/runtime.env"
descriptor="$ROOT_DIR/services/vector/external-release.json"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/vector-smoke-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

[[ -x "$smoke" ]] || {
  printf 'Vector smoke script is missing or not executable: %s\n' "$smoke" >&2
  exit 1
}
[[ -f "$recipe" && -f "$runtime" && -f "$descriptor" ]] || {
  printf 'Vector service metadata is incomplete\n' >&2
  exit 1
}

# The service smoke must reject an invocation without an execution surface.
if env -u IMAGE -u ARTIFACT_ROOTFS "$smoke" >"$test_dir/missing-surface.out" 2>&1; then
  printf 'Vector smoke unexpectedly passed without IMAGE or ARTIFACT_ROOTFS\n' >&2
  exit 1
fi
grep -q 'set IMAGE to smoke a Docker image, or ARTIFACT_ROOTFS to smoke an extracted artifact' \
  "$test_dir/missing-surface.out"

python3 - "$recipe" "$runtime" "$descriptor" <<'PY'
import json
import pathlib
import sys

recipe_path, runtime_path, descriptor_path = map(pathlib.Path, sys.argv[1:])
recipe = recipe_path.read_text(encoding="utf-8")
runtime = runtime_path.read_text(encoding="utf-8")
descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))

assert 'ARTIFACT_BACKEND="upstream-archive"' in recipe
assert 'UPSTREAM_ASSETS_FILE:?UPSTREAM_ASSETS_FILE must be supplied by workflow context' in recipe
assert 'CMD_JSON=' in recipe and '["/bin/vector"]' in recipe
assert "ENTRYPOINT_JSON='[]'" in recipe
assert 'UPSTREAM_ARCHIVE_EXECUTABLES_JSON=' in recipe
assert 'SUPPORTS_DIRECT_ARTIFACT_SMOKE="true"' in recipe
assert 'IMAGE_RELEASE_MODE="mirror"' in recipe
assert 'VECTOR_THREADS=1' in runtime
assert descriptor["github"]["repository"] == "vectordotdev/vector"
assert descriptor["github"]["release_tag_template"] == "v{version}"
assert descriptor["oci"] == {
    "repository": "docker.io/timberio/vector",
    "tag_template": "{version}-alpine",
    "required_platforms": ["linux/amd64", "linux/arm64"],
}
assert set(descriptor["github"]["artifact"]["targets"]) == {
    "darwin-arm64", "linux-amd64", "linux-arm64"
}
PY

# CI and local verification can opt into the full current-platform protocol
# smoke by pointing this test at an already-built extracted artifact.
if [[ -n "${ARTIFACT_ROOTFS:-}" ]]; then
  ARTIFACT_ROOTFS="$ARTIFACT_ROOTFS" "$smoke"
fi

printf 'vector smoke integration tests passed\n'
