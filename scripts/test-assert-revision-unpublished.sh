#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(sys.argv[1])
GUARD = ROOT / "scripts" / "assert-revision-unpublished.sh"
GH_REPO = "supabase/slim-services"
RELEASE_TAG = "auth-v2.197.0-r0"
EXPECTED_ENDPOINT = f"repos/{GH_REPO}/releases/tags/{RELEASE_TAG}"


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def run_guard(gh_script, env_overrides=None):
    with tempfile.TemporaryDirectory(prefix="assert-revision-unpublished-test.") as name:
        bin_dir = pathlib.Path(name) / "bin"
        bin_dir.mkdir()
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(gh_script, encoding="utf-8")
        fake_gh.chmod(0o755)
        env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "GH_TOKEN": "test-token",
            "GH_REPO": GH_REPO,
        }
        if env_overrides:
            env.update(env_overrides)
        return subprocess.run(
            [str(GUARD), RELEASE_TAG], text=True, capture_output=True, env=env, cwd=ROOT
        )


# Every fake `gh` below asserts the exact argv the guard is expected to call
# (`gh api -i repos/<GH_REPO>/releases/tags/<tag>`), so the test fails if the
# endpoint the guard queries ever changes.
ARGV_GUARD = f'''
case "$*" in
  "api -i {EXPECTED_ENDPOINT}") ;;
  *)
    printf 'unexpected gh invocation: %s\\n' "$*" >&2
    exit 2
    ;;
esac
'''

PUBLISHED_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    + ARGV_GUARD
    + "printf 'HTTP/2.0 200 OK\\r\\nContent-Type: application/json\\r\\n\\r\\n{\"tag_name\":\"" + RELEASE_TAG + "\"}\\n'\n"
)

NOT_FOUND_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    + ARGV_GUARD
    + "printf 'gh: Not Found (HTTP 404)\\n' >&2\n"
    "exit 1\n"
)

API_ERROR_500_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    + ARGV_GUARD
    + "printf 'gh: Internal Server Error (HTTP 500)\\n' >&2\n"
    "exit 1\n"
)

SECONDARY_RATE_LIMIT_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    + ARGV_GUARD
    + "printf 'gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again (HTTP 403)\\n' >&2\n"
    "exit 1\n"
)

# Models the fail-open shape this guard replaces: `gh release view`'s combined
# REST + GraphQL lookup can surface "release not found" even when the
# underlying REST call actually errored on a published release. The guard no
# longer calls `gh release view`, and must not treat this free-form text as a
# 404 either: only the literal "(HTTP 404)" form exits 0.
OLD_FAIL_OPEN_SHAPE_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    + ARGV_GUARD
    + "printf 'release not found\\n' >&2\n"
    "exit 1\n"
)


def test_published_release_fails_with_the_immutability_message():
    result = run_guard(PUBLISHED_GH)
    assert_true(result.returncode == 1, f"expected exit 1: {result.returncode} {result.stderr}")
    assert_true(
        f"release {RELEASE_TAG} is already published; revisions are immutable. "
        "Dispatch a new run (hotfix=true for a new revision)." in result.stderr,
        result.stderr,
    )


def test_missing_release_exits_zero():
    result = run_guard(NOT_FOUND_GH)
    assert_true(result.returncode == 0, result.stderr)


def test_draft_release_exits_zero():
    # The releases-by-tag REST endpoint 404s for drafts exactly as it does for
    # a missing release, so the guard cannot and need not tell them apart.
    result = run_guard(NOT_FOUND_GH)
    assert_true(result.returncode == 0, result.stderr)


def test_api_error_500_is_not_read_as_unpublished():
    result = run_guard(API_ERROR_500_GH)
    assert_true(result.returncode != 0, f"expected non-zero: {result.returncode}")
    assert_true("already published" not in result.stderr, result.stderr)
    assert_true("HTTP 500" in result.stderr, result.stderr)


def test_secondary_rate_limit_is_not_read_as_unpublished():
    result = run_guard(SECONDARY_RATE_LIMIT_GH)
    assert_true(result.returncode != 0, f"expected non-zero: {result.returncode}")
    assert_true("already published" not in result.stderr, result.stderr)


def test_old_fail_open_shape_is_not_read_as_unpublished():
    result = run_guard(OLD_FAIL_OPEN_SHAPE_GH)
    assert_true(result.returncode != 0, f"expected non-zero, not the old fail-open exit 0: {result.returncode}")


def test_missing_gh_repo_fails_clearly():
    with tempfile.TemporaryDirectory(prefix="assert-revision-unpublished-test.") as name:
        bin_dir = pathlib.Path(name) / "bin"
        bin_dir.mkdir()
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(NOT_FOUND_GH, encoding="utf-8")
        fake_gh.chmod(0o755)
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "GH_TOKEN": "test-token"}
        env.pop("GH_REPO", None)
        result = subprocess.run(
            [str(GUARD), RELEASE_TAG], text=True, capture_output=True, env=env, cwd=ROOT
        )
        assert_true(result.returncode != 0, f"expected non-zero: {result.returncode}")
        assert_true("GH_REPO" in result.stderr, result.stderr)


tests = [value for name, value in globals().items() if name.startswith("test_")]
for test in tests:
    test()
print(f"revision unpublished guard tests passed ({len(tests)} tests)")
PY
