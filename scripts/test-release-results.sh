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
DOWNLOAD = ROOT / "scripts" / "download-latest-release-manifests.sh"
TABLES = "scripts/update-results-tables.sh"

# A mixed release list: a legacy tag with no -rN, two -r0 releases, and a
# hotfix -r1 on top of the newest upstream version. Mirrors the D1 grammar
# from the design doc: only the highest upstream version's highest revision
# is a candidate, and the legacy tag is frozen history.
RELEASES = [
    {"tag_name": "storage-v1.79.23", "draft": False, "prerelease": False},
    {"tag_name": "storage-v1.79.22-r0", "draft": False, "prerelease": False},
    {"tag_name": "storage-v1.79.23-r0", "draft": False, "prerelease": False},
    {"tag_name": "storage-v1.79.23-r1", "draft": False, "prerelease": False},
]
CHOSEN_TAG = "storage-v1.79.23-r1"
CHOSEN_VERSION = "v1.79.23-r1"
CHOSEN_UPSTREAM = "v1.79.23"

FAKE_GH = (
    "#!/bin/sh\n"
    "set -eu\n"
    "case \"$1\" in\n"
    "  api) cat \"$FAKE_RELEASES_JSON\" ;;\n"
    "  release)\n"
    "    if [ \"$2\" = download ]; then\n"
    "      tag=\"$3\"\n"
    "      shift 3\n"
    "      dir=\"\"\n"
    "      while [ $# -gt 0 ]; do\n"
    "        case \"$1\" in\n"
    "          --dir) dir=\"$2\"; shift 2 ;;\n"
    "          *) shift ;;\n"
    "        esac\n"
    "      done\n"
    "      src=\"$FAKE_MANIFESTS_DIR/$tag\"\n"
    "      if [ -d \"$src\" ]; then cp \"$src\"/*.manifest.json \"$dir/\"; exit 0; fi\n"
    "      exit 1\n"
    "    fi\n"
    "    exit 1\n"
    "    ;;\n"
    "  *) exit 1 ;;\n"
    "esac\n"
)


def run(command, *, cwd, env, check=False):
    merged = os.environ.copy()
    merged.update(env)
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, env=merged, check=check)


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def tracked_files():
    result = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=True
    )
    return [line for line in result.stdout.splitlines() if line]


def copy_repo(destination):
    """A working-tree copy (including uncommitted edits) of every tracked file, so
    scripts/update-results-tables.sh's ROOT_DIR-relative README.md and recipe.env
    lookups resolve inside the sandbox instead of touching the real repository."""
    for relative in tracked_files():
        source = ROOT / relative
        if not source.is_file():
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(source, target)


def test_download_selects_the_highest_upstream_version_and_revision():
    with tempfile.TemporaryDirectory(prefix="release-results-download.") as name:
        workdir = pathlib.Path(name)
        bin_dir = workdir / "bin"
        bin_dir.mkdir()
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(FAKE_GH, encoding="utf-8")
        fake_gh.chmod(0o755)

        releases_json = workdir / "releases.json"
        releases_json.write_text(json.dumps([RELEASES]), encoding="utf-8")

        config = workdir / "service-release-sources.json"
        config.write_text(
            json.dumps({"services": {"storage": {"tag_pattern": r"^v[0-9]+\.[0-9]+\.[0-9]+$"}}}),
            encoding="utf-8",
        )

        manifests_dir = workdir / "manifests" / CHOSEN_TAG
        manifests_dir.mkdir(parents=True)
        for platform_dir, platform in (("linux-arm64", "linux/arm64"), ("darwin-arm64", "darwin/arm64")):
            (manifests_dir / f"{CHOSEN_TAG}-{platform_dir}.manifest.json").write_text(
                json.dumps(
                    {
                        "service": "storage",
                        "version": CHOSEN_VERSION,
                        "upstream_version": CHOSEN_UPSTREAM,
                        "revision": 1,
                        "platform": platform,
                    }
                ),
                encoding="utf-8",
            )

        artifacts_dir = workdir / "artifacts"
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "GH_TOKEN": "test-token",
            "SERVICE_RELEASE_CONFIG": str(config),
            "RELEASE_RESULTS_REPOSITORY": "supabase/slim-services",
            "RESULTS_ARTIFACTS_DIR": str(artifacts_dir),
            "FAKE_RELEASES_JSON": str(releases_json),
            "FAKE_MANIFESTS_DIR": str(manifests_dir.parent),
        }
        result = run([str(DOWNLOAD)], cwd=workdir, env=env)
        assert_true(result.returncode == 0, result.stdout + result.stderr)
        assert_true(f"downloading manifests for storage ({CHOSEN_TAG})" in result.stdout, result.stdout)
        assert_true("v1.79.22" not in result.stdout, result.stdout)

        placed = artifacts_dir / "storage" / CHOSEN_VERSION / "linux-arm64" / "manifest.json"
        assert_true(placed.is_file(), f"missing {placed}")
        placed_manifest = json.loads(placed.read_text(encoding="utf-8"))
        assert_true(placed_manifest["version"] == CHOSEN_VERSION, placed_manifest)
        assert_true(placed_manifest["upstream_version"] == CHOSEN_UPSTREAM, placed_manifest)

        assert_true(not (artifacts_dir / "storage" / "v1.79.23").exists(), "legacy tag must never be downloaded")
        assert_true(not (artifacts_dir / "storage" / "v1.79.22-r0").exists(), "older revision must not be selected")
        assert_true(not (artifacts_dir / "storage" / "v1.79.23-r0").exists(), "older revision must not be selected")


def test_results_table_shows_upstream_version_and_links_to_the_release_revision():
    with tempfile.TemporaryDirectory(prefix="release-results-table.") as name:
        workdir = pathlib.Path(name)
        repo = workdir / "repo"
        copy_repo(repo)

        artifacts_dir = workdir / "artifacts"
        manifest_dir = artifacts_dir / "storage" / CHOSEN_VERSION / "darwin-arm64"
        manifest_dir.mkdir(parents=True)
        (manifest_dir / "manifest.json").write_text(
            json.dumps(
                {
                    "service": "storage",
                    "version": CHOSEN_VERSION,
                    "upstream_version": CHOSEN_UPSTREAM,
                    "revision": 1,
                    "size": {"archive_mib": 5.1, "rootfs_mib": 6.2},
                    "runtime": {"runtime_rss_mib": 20.4, "idle_cpu_pct": 0.05},
                    "portable": True,
                }
            ),
            encoding="utf-8",
        )

        env = {
            "RESULTS_ARTIFACTS_DIR": str(artifacts_dir),
            "RELEASE_RESULTS_REPOSITORY": "supabase/slim-services",
        }
        result = run(
            [str(repo / TABLES), "--host-native-only", "--published"],
            cwd=repo,
            env=env,
        )
        assert_true(result.returncode == 0, result.stdout + result.stderr)

        readme = (repo / "README.md").read_text(encoding="utf-8")
        block = readme.split("<!-- generated:host-native:begin -->", 1)[1].split(
            "<!-- generated:host-native:end -->", 1
        )[0]
        row = next((line for line in block.splitlines() if line.startswith("| Storage ")), None)
        assert_true(row is not None, f"no Storage row in host-native table:\n{block}")
        assert_true(f"`{CHOSEN_UPSTREAM}`" in row, f"row does not display the upstream version: {row}")
        assert_true(f"`{CHOSEN_VERSION}`" not in row, f"row must not display the release revision: {row}")
        assert_true(
            f"releases/tag/storage-{CHOSEN_VERSION}" in row,
            f"row does not link to the release revision: {row}",
        )


tests = [value for name, value in globals().items() if name.startswith("test_")]
for test in tests:
    test()
print(f"release results tests passed ({len(tests)} tests)")
PY
