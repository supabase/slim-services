#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(sys.argv[1])
PLANNER = ROOT / "scripts" / "plan-release-revision.sh"


def run(command, *, env=None, check=False):
    merged = os.environ.copy()
    merged.update(env or {})
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, env=merged, check=check)


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def tags_with_filler(real_tags):
    real_tags = list(real_tags)
    filler_count = 250 - len(real_tags)
    assert_true(filler_count >= 200, "filler budget leaves fewer than 200 tags before the real ones")
    filler = [f"filler-service-{index}.0.0-r0" for index in range(filler_count)]
    return filler + real_tags


def plan(service, upstream_version, validation_only, hotfix, git_ref, tags):
    with tempfile.TemporaryDirectory(prefix="plan-release-revision-test.") as name:
        directory = pathlib.Path(name)
        bin_dir = directory / "bin"
        bin_dir.mkdir()
        fixture = directory / "tags"
        fixture.write_text("\n".join(tags) + ("\n" if tags else ""), encoding="utf-8")
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "cat \"$FAKE_TAGS\"\n",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "GH_REPO": "supabase/slim-services",
            "GH_TOKEN": "test-token",
            "FAKE_TAGS": str(fixture),
        }
        return run(
            [str(PLANNER), service, upstream_version, validation_only, hotfix, git_ref],
            env=env,
        )


def test_no_revision_published_allocates_r0():
    result = plan("auth", "v2.197.0", "false", "false", "refs/heads/main", tags_with_filler(["auth-v2.197.0"]))
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["publish"] is True, f"expected publish: {parsed}")
    assert_true(parsed["revision"] == 0, f"expected revision 0: {parsed}")
    assert_true(parsed["release_tag"] == "auth-v2.197.0-r0", f"unexpected release_tag: {parsed}")


def test_taken_without_hotfix_skips_build_and_publish():
    result = plan(
        "auth", "v2.197.0", "false", "false", "refs/heads/main", tags_with_filler(["auth-v2.197.0-r0"])
    )
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["build"] is False, f"expected no build: {parsed}")
    assert_true(parsed["publish"] is False, f"expected no publish: {parsed}")


def test_taken_plus_hotfix_allocates_next_revision():
    result = plan(
        "auth",
        "v2.197.0",
        "false",
        "true",
        "refs/heads/main",
        tags_with_filler(["auth-v2.197.0-r0", "auth-v2.197.0-r1"]),
    )
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["revision"] == 2, f"expected revision 2: {parsed}")


def test_hotfix_with_nothing_taken_fails():
    result = plan("auth", "v2.197.0", "false", "true", "refs/heads/main", tags_with_filler([]))
    assert_true(result.returncode == 1, f"expected exit 1: {result.returncode}")
    assert_true("no published revision" in result.stderr, result.stderr)


def test_hotfix_and_validation_only_are_exclusive():
    result = plan("auth", "v2.197.0", "true", "true", "refs/heads/main", tags_with_filler([]))
    assert_true(result.returncode == 1, f"expected exit 1: {result.returncode}")
    assert_true("exclusive" in result.stderr, result.stderr)


def test_revision_past_pagination_boundary_is_counted():
    result = plan(
        "beacon",
        "v1.0.0",
        "false",
        "true",
        "refs/heads/main",
        tags_with_filler(["beacon-v1.0.0-r0"]),
    )
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["revision"] == 1, f"expected revision 1: {parsed}")


def test_prefix_collision_does_not_match_a_longer_upstream_version():
    result = plan(
        "storage",
        "v1.79.2",
        "false",
        "false",
        "refs/heads/main",
        tags_with_filler(["storage-v1.79.23-r0", "storage-v1.79.23-r1"]),
    )
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["revision"] == 0, f"expected revision 0: {parsed}")
    assert_true(parsed["publish"] is True, f"expected publish: {parsed}")


def test_studio_dashes_in_upstream_version_are_not_ambiguous():
    result = plan(
        "studio",
        "2026.09.04-sha-5a67366",
        "false",
        "false",
        "refs/heads/main",
        tags_with_filler(["studio-2026.09.04-sha-5a67366-r0"]),
    )
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["publish"] is False, f"expected no publish: {parsed}")


def test_non_main_publish_fails():
    result = plan("auth", "v2.197.0", "false", "false", "refs/heads/feature", tags_with_filler([]))
    assert_true(result.returncode == 1, f"expected exit 1: {result.returncode}")
    assert_true("requires refs/heads/main" in result.stderr, result.stderr)


def test_non_main_validation_only_succeeds():
    result = plan("auth", "v2.197.0", "true", "false", "refs/heads/feature", tags_with_filler([]))
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["build"] is True, f"expected build: {parsed}")
    assert_true(parsed["publish"] is False, f"expected no publish: {parsed}")
    assert_true(parsed["revision"] == 0, f"expected revision 0: {parsed}")


def test_regex_metacharacters_in_upstream_version_do_not_cross_match():
    result = plan(
        "postgrest",
        "v14.16",
        "false",
        "true",
        "refs/heads/main",
        tags_with_filler(["postgrest-v14x16-r0"]),
    )
    assert_true(result.returncode == 1, f"expected exit 1: {result.returncode}")
    assert_true("no published revision" in result.stderr, result.stderr)


tests = [value for name, value in globals().items() if name.startswith("test_")]
for test in tests:
    test()
print(f"release revision planner tests passed ({len(tests)} tests)")
PY
