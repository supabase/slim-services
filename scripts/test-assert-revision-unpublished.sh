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


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def run_guard(gh_script):
    with tempfile.TemporaryDirectory(prefix="assert-revision-unpublished-test.") as name:
        bin_dir = pathlib.Path(name) / "bin"
        bin_dir.mkdir()
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(gh_script, encoding="utf-8")
        fake_gh.chmod(0o755)
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "GH_TOKEN": "test-token"}
        return subprocess.run(
            [str(GUARD), "auth-v2.197.0-r0"], text=True, capture_output=True, env=env, cwd=ROOT
        )


NOT_FOUND_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    "printf 'release not found\\n' >&2\n"
    "exit 1\n"
)

DRAFT_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    "printf '{\"isDraft\":true}\\n'\n"
)

PUBLISHED_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    "printf '{\"isDraft\":false}\\n'\n"
)

API_ERROR_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    "printf 'HTTP 500: internal error\\n' >&2\n"
    "exit 1\n"
)


def test_missing_release_exits_zero():
    result = run_guard(NOT_FOUND_GH)
    assert_true(result.returncode == 0, result.stderr)


def test_draft_release_exits_zero():
    result = run_guard(DRAFT_GH)
    assert_true(result.returncode == 0, result.stderr)


def test_published_release_fails_with_the_immutability_message():
    result = run_guard(PUBLISHED_GH)
    assert_true(result.returncode == 1, f"expected exit 1: {result.returncode}")
    assert_true(
        "release auth-v2.197.0-r0 is already published; revisions are immutable. "
        "Dispatch a new run (hotfix=true for a new revision)." in result.stderr,
        result.stderr,
    )


def test_other_gh_failure_is_not_read_as_unpublished():
    result = run_guard(API_ERROR_GH)
    assert_true(result.returncode != 0, f"expected a non-zero exit: {result.returncode}")
    assert_true("already published" not in result.stderr, result.stderr)
    assert_true("HTTP 500" in result.stderr, result.stderr)


tests = [value for name, value in globals().items() if name.startswith("test_")]
for test in tests:
    test()
print(f"revision unpublished guard tests passed ({len(tests)} tests)")
PY
