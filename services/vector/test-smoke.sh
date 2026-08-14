#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

smoke="$ROOT_DIR/services/vector/smoke.sh"
recipe="$ROOT_DIR/services/vector/recipe.env"
runtime="$ROOT_DIR/services/vector/runtime.env"
policy="$ROOT_DIR/services/vector/upstream-assets.json"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/vector-smoke-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

[[ -x "$smoke" ]] || {
  printf 'Vector smoke script is missing or not executable: %s\n' "$smoke" >&2
  exit 1
}
[[ -f "$recipe" && -f "$runtime" && -f "$policy" ]] || {
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

python3 - "$recipe" "$runtime" "$policy" <<'PY'
import json
import pathlib
import sys

recipe_path, runtime_path, policy_path = map(pathlib.Path, sys.argv[1:])
recipe = recipe_path.read_text(encoding="utf-8")
runtime = runtime_path.read_text(encoding="utf-8")
policy = json.loads(policy_path.read_text(encoding="utf-8"))

assert 'ARTIFACT_BACKEND="upstream-archive"' in recipe
assert 'CMD_JSON=' in recipe and '["/bin/vector"]' in recipe
assert "ENTRYPOINT_JSON='[]'" in recipe
assert 'UPSTREAM_ARCHIVE_EXECUTABLES_JSON=' in recipe
assert 'SUPPORTS_DIRECT_ARTIFACT_SMOKE="true"' in recipe
assert 'IMAGE_RELEASE_MODE="mirror"' in recipe
assert 'VECTOR_THREADS=1' in runtime
assert policy["repository"] == "vectordotdev/vector"
record = policy["versions"]["0.53.0"]
assert record["release_tag"] == "v0.53.0"
assert record["image"] == {
    "source": "docker.io/timberio/vector:0.53.0-alpine",
    "index_digest": "sha256:ca92d617e905953c3f852e7e88061f7039460e733522e3f0c21bc6ae946b2558",
    "platforms": {
        "linux/amd64": "sha256:7a74872eb7791f65357b200813bcf613c8dedcac561b4f1a68f9d290f6e6a40c",
        "linux/arm64": "sha256:d2d5381f69b885c1b10d396623bf8d5ce825bcb8f8efcdb14a3154223c13b3b7",
    },
}
assert set(record["assets"]) == {"darwin-arm64", "linux-amd64", "linux-arm64"}
PY

# CI and local verification can opt into the full current-platform protocol
# smoke by pointing this test at an already-built extracted artifact.
if [[ -n "${ARTIFACT_ROOTFS:-}" ]]; then
  ARTIFACT_ROOTFS="$ARTIFACT_ROOTFS" "$smoke"
fi

printf 'vector smoke integration tests passed\n'
