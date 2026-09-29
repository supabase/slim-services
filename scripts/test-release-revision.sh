#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(sys.argv[1])
PLANNER = ROOT / "scripts" / "plan-release-revision.sh"
GH_REPO = "supabase/slim-services"

if shutil.which("jq") is None:
    raise SystemExit(
        "jq is required to run these tests (the fake gh runs the real --jq "
        "filter through it); install jq and retry"
    )

# Runs the real `--jq` filter the planner passes (extracted from argv below)
# through the real `jq`, rather than reimplementing it, so a regression in
# the filter (for example dropping the draft exclusion) fails these tests
# instead of a hand-written stand-in silently papering over it. `jq -s`
# slurps the JSONL fixture (one release record per line) into the array the
# filter's `.[] | ...` expects.
DEFAULT_FAKE_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    "printf '%s\\n' \"$*\" >> \"$FAKE_GH_ARGV\"\n"
    "jq_filter=\"\"\n"
    "prev=\"\"\n"
    "for arg in \"$@\"; do\n"
    "  [ \"$prev\" = \"--jq\" ] && jq_filter=\"$arg\"\n"
    "  prev=\"$arg\"\n"
    "done\n"
    "case \" $* \" in\n"
    "  *' --paginate '*) cat \"$FAKE_TAGS\" ;;\n"
    "  *) head -n 100 \"$FAKE_TAGS\" ;;\n"
    "esac | jq -s -r \"$jq_filter\"\n"
)

FAILING_FAKE_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    "printf '%s\\n' \"$*\" >> \"$FAKE_GH_ARGV\"\n"
    "printf 'gh: request failed\\n' >&2\n"
    "exit 1\n"
)


def run(command, *, env=None, check=False):
    merged = os.environ.copy()
    merged.update(env or {})
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, env=merged, check=check)


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def draft_tag(name):
    return (name, True)


def _as_record(tag):
    if isinstance(tag, tuple):
        name, draft = tag
    else:
        name, draft = tag, False
    return {"tag_name": name, "draft": draft}


def tags_with_filler(real_tags):
    real_tags = list(real_tags)
    filler_count = 250 - len(real_tags)
    assert_true(filler_count >= 200, "filler budget leaves fewer than 200 tags before the real ones")
    filler = [f"filler-service-{index}.0.0-r0" for index in range(filler_count)]
    return filler + real_tags


def plan(service, upstream_version, validation_only, hotfix, git_ref, tags, *, gh_script=None):
    with tempfile.TemporaryDirectory(prefix="plan-release-revision-test.") as name:
        directory = pathlib.Path(name)
        bin_dir = directory / "bin"
        bin_dir.mkdir()
        fixture = directory / "tags"
        fixture.write_text(
            "".join(json.dumps(_as_record(tag)) + "\n" for tag in tags), encoding="utf-8"
        )
        argv_file = directory / "gh-argv"
        argv_file.write_text("", encoding="utf-8")
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(gh_script or DEFAULT_FAKE_GH, encoding="utf-8")
        fake_gh.chmod(0o755)
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "GH_REPO": GH_REPO,
            "GH_TOKEN": "test-token",
            "FAKE_TAGS": str(fixture),
            "FAKE_GH_ARGV": str(argv_file),
        }
        result = run(
            [str(PLANNER), service, upstream_version, validation_only, hotfix, git_ref],
            env=env,
        )
        result.argv = argv_file.read_text(encoding="utf-8").strip()
        return result


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


def test_draft_release_does_not_count_as_taken():
    result = plan(
        "auth",
        "v2.197.0",
        "false",
        "false",
        "refs/heads/main",
        tags_with_filler([draft_tag("auth-v2.197.0-r0")]),
    )
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["publish"] is True, f"expected publish: {parsed}")
    assert_true(parsed["revision"] == 0, f"expected revision 0, draft is not taken: {parsed}")


def test_hotfix_ignores_a_draft_revision_on_top_of_a_published_one():
    result = plan(
        "auth",
        "v2.197.0",
        "false",
        "true",
        "refs/heads/main",
        tags_with_filler(["auth-v2.197.0-r0", draft_tag("auth-v2.197.0-r1")]),
    )
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["revision"] == 1, f"expected revision 1, draft r1 is not taken: {parsed}")


def test_blank_service_is_rejected():
    result = plan("", "v2.197.0", "false", "false", "refs/heads/main", tags_with_filler([]))
    assert_true(result.returncode == 2, f"expected exit 2: {result.returncode} {result.stderr}")


def test_blank_upstream_version_is_rejected():
    result = plan("auth", "", "false", "false", "refs/heads/main", tags_with_filler([]))
    assert_true(result.returncode == 2, f"expected exit 2: {result.returncode} {result.stderr}")


def test_blank_git_ref_is_rejected():
    result = plan("auth", "v2.197.0", "false", "false", "", tags_with_filler([]))
    assert_true(result.returncode == 2, f"expected exit 2: {result.returncode} {result.stderr}")


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
    assert_true(
        result.argv
        == f"api --paginate repos/{GH_REPO}/releases?per_page=100 --jq .[] | select(.draft | not) | .tag_name",
        f"unexpected gh invocation: {result.argv!r}",
    )
    parsed = json.loads(result.stdout)
    assert_true(parsed["revision"] == 1, f"expected revision 1: {parsed}")


def test_gh_failure_is_not_read_as_nothing_taken():
    result = plan(
        "auth",
        "v2.197.0",
        "false",
        "false",
        "refs/heads/main",
        [],
        gh_script=FAILING_FAKE_GH,
    )
    assert_true(result.returncode != 0, f"expected non-zero exit: {result.returncode}")
    assert_true(result.stdout == "", f"expected no stdout on gh failure: {result.stdout!r}")


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
