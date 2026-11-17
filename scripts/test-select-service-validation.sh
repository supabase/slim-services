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
import unittest


ROOT = pathlib.Path(sys.argv.pop(1))
SELECTOR = ROOT / "scripts" / "select-service-validation.sh"
REGISTRY = ".github/service-release-sources.json"

for tool in ("jq", "git"):
    if shutil.which(tool) is None:
        raise SystemExit(f"{tool} is required to run these tests")


def entry(repository, floor=None, **extra):
    config = {
        "repository": repository,
        "tag_pattern": r"^v[0-9]+\.[0-9]+\.[0-9]+$",
        "poll": True,
        **extra,
    }
    if floor is not None:
        config["release_floor"] = floor
    return config


# Registry order is the order the selector reports services in.
BASE_REGISTRY = {
    "services": {
        "auth": entry("supabase/auth", "v1.0.0"),
        "realtime": entry("supabase/realtime", "v2.0.0"),
        "mailpit": entry(
            "axllent/mailpit",
            external_release_descriptor="services/mailpit/external-release.json",
            poll=False,
        ),
    }
}

AUTH = ["auth\tv1.0.0", "auth\tv1.2.0"]
REALTIME = ["realtime\tv2.0.0", "realtime\tv2.1.0"]
MAILPIT = ["mailpit\tv1.5.0"]


def include(*lines):
    return {
        "include": [
            {"service": service, "version": version}
            for service, version in (line.split("\t") for line in lines)
        ]
    }


class SelectServiceValidationTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="select-validation-test.")
        self.directory = pathlib.Path(self.temporary_directory.name)
        self.addCleanup(self.temporary_directory.cleanup)
        self.repo = self.directory / "repo"
        self.repo.mkdir()
        self.fake_bin = self.directory / "bin"
        self.fake_bin.mkdir()
        self.upstream = self.directory / "upstream"
        self.upstream.mkdir()
        self.trace = self.directory / "gh-trace"
        self.published = self.directory / "published"

        # Fake gh: the poller's release listings come from files; anything
        # other than a releases listing (gh run list, workflow dispatch) is a
        # failure, since selection must be read-only.
        fake_gh = self.fake_bin / "gh"
        fake_gh.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >> \"$FAKE_GH_TRACE\"\n"
            "[ \"$1\" = api ] || { printf 'unexpected gh invocation: %s\\n' \"$*\" >&2; exit 2; }\n"
            "endpoint=''; jq_filter=''; prev=''\n"
            "for arg in \"$@\"; do\n"
            "  case \"$arg\" in repos/*) endpoint=\"$arg\" ;; esac\n"
            "  [ \"$prev\" = --jq ] && jq_filter=\"$arg\"\n"
            "  prev=\"$arg\"\n"
            "done\n"
            "case \"$endpoint\" in\n"
            "  repos/supabase/slim-services/releases*) jq -r \"$jq_filter\" \"$FAKE_PUBLISHED_RELEASES\" ;;\n"
            "  repos/*/releases*) name=${endpoint#repos/}; name=${name%%/releases*}; cat \"$FAKE_UPSTREAM_DIR/$(printf '%s' \"$name\" | tr / _)\" ;;\n"
            "  *) printf 'unexpected gh api endpoint: %s\\n' \"$endpoint\" >&2; exit 2 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)

        self.set_upstream("supabase/auth", ["v1.2.0", "v1.1.0", "v1.0.0"])
        self.set_upstream("supabase/realtime", ["v2.1.0", "v2.0.0"])
        self.published.write_text(
            json.dumps(
                [
                    {"tag_name": tag, "draft": False}
                    for tag in (
                        "auth-v1.1.0-r0",
                        "mailpit-v1.4.0-r0",
                        "mailpit-v1.5.0-r1",
                    )
                ]
            ),
            encoding="utf-8",
        )

        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        self.git("config", "commit.gpgsign", "false")
        self.root_commit = self.commit({"README.md": "readme\n"})
        files = {
            "services/auth/build.sh": "auth\n",
            "services/realtime/build.sh": "realtime\n",
            "services/mailpit/external-release.json": "{}\n",
            "services/unknown/build.sh": "unknown\n",
            "sources/auth": "pointer\n",
            "sources/realtime": "pointer\n",
            "scripts/foo.sh": "foo\n",
            "scripts/test-foo.sh": "test\n",
            "scripts/foo.test.ts": "test\n",
            "nix/x.nix": "nix\n",
            "flake.nix": "flake\n",
            "flake.lock": "{}\n",
            ".gitmodules": "modules\n",
            ".dockerignore": "ignore\n",
            ".gitignore": "ignore\n",
            "LICENSE": "license\n",
            "docs/guide.txt": "guide\n",
            ".github/workflows/other.yml": "other\n",
            ".github/workflows/service-release.yml": "release\n",
            ".github/workflows/service-validation.yml": "validation\n",
            ".github/CODEOWNERS": "owners\n",
            REGISTRY: json.dumps(BASE_REGISTRY, indent=2) + "\n",
        }
        self.base = self.commit(files)

    def set_upstream(self, repository, tags):
        (self.upstream / repository.replace("/", "_")).write_text(
            "".join(f"{tag}\n" for tag in tags), encoding="utf-8"
        )

    def git(self, *args):
        return subprocess.run(
            ["git", *args],
            cwd=self.repo,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()

    def commit(self, files):
        for name, content in files.items():
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            if content is None:
                path.unlink()
            else:
                path.write_text(content, encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "change")
        return self.git("rev-parse", "HEAD")

    def head_with(self, files):
        # Every case branches from the same base commit.
        self.git("reset", "-q", "--hard", self.base)
        return self.commit(files)

    def registry_with(self, mutate):
        registry = json.loads(json.dumps(BASE_REGISTRY))
        mutate(registry)
        return {REGISTRY: json.dumps(registry, indent=2) + "\n"}

    def select(self, base, head):
        environment = {
            **os.environ,
            "PATH": f"{self.fake_bin}:{os.environ['PATH']}",
            "GH_TOKEN": "test-token",
            "SERVICE_RELEASE_CONFIG": str(self.repo / REGISTRY),
            "FAKE_GH_TRACE": str(self.trace),
            "FAKE_PUBLISHED_RELEASES": str(self.published),
            "FAKE_UPSTREAM_DIR": str(self.upstream),
        }
        return subprocess.run(
            [str(SELECTOR), base, head],
            cwd=self.repo,
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )

    def assert_selection(self, files, expected_lines, base=None):
        if self.trace.exists():
            self.trace.unlink()
        head = self.head_with(files)
        result = self.select(base or self.base, head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), include(*expected_lines))
        # Compact single-line JSON, ready for a workflow matrix.
        self.assertEqual(
            result.stdout.strip(),
            json.dumps(include(*expected_lines), separators=(",", ":")),
        )
        self.assertIn("selected pairs:", result.stderr)
        return result

    def assert_nothing_selected(self, files):
        result = self.assert_selection(files, [])
        self.assertFalse(self.trace.exists(), "the poller must not run")
        self.assertIn("selected services: none", result.stderr)
        return result

    def test_ignored_paths_select_nothing_and_skip_the_poller(self):
        result = self.assert_nothing_selected(
            {
                "README.md": "changed\n",
                "docs/guide.txt": "changed\n",
                "docs/nested/more.html": "new\n",
                "services/auth/NOTES.md": "notes\n",
                "LICENSE": "changed\n",
                ".gitignore": "changed\n",
                ".gitattributes": "changed\n",
                "scripts/test-foo.sh": "changed\n",
                "scripts/foo.test.ts": "changed\n",
                ".github/workflows/other.yml": "changed\n",
                ".github/CODEOWNERS": "changed\n",
            }
        )
        self.assertIn("README.md -> ignored", result.stderr)
        self.assertIn(".github/workflows/other.yml -> ignored", result.stderr)

    def test_no_changes_select_nothing(self):
        head = self.head_with({})
        result = self.select(self.base, head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"include": []})
        self.assertFalse(self.trace.exists())

    def test_service_directory_selects_that_service(self):
        result = self.assert_selection({"services/realtime/build.sh": "changed\n"}, REALTIME)
        self.assertIn("services/realtime/build.sh -> realtime", result.stderr)

    def test_selected_services_follow_registry_order_with_floor_and_newest(self):
        self.assert_selection(
            {
                "services/mailpit/new.txt": "x\n",
                "services/auth/build.sh": "changed\n",
                "services/auth/lib.sh": "new\n",
            },
            AUTH + MAILPIT,
        )

    def test_unregistered_service_directory_is_ignored_with_a_notice(self):
        result = self.assert_nothing_selected({"services/unknown/build.sh": "changed\n"})
        self.assertIn("not a registered service", result.stderr)

    def test_source_pointer_selects_its_service_or_everything_when_unknown(self):
        self.assert_selection({"sources/auth": "bumped\n"}, AUTH)
        self.assert_selection(
            {"sources/mystery": "pointer\n"}, AUTH + REALTIME + MAILPIT
        )

    def test_registry_change_selects_only_services_whose_entry_changed(self):
        def raise_realtime_floor(registry):
            registry["services"]["realtime"]["release_floor"] = "v2.1.0"

        self.assert_selection(self.registry_with(raise_realtime_floor), ["realtime\tv2.1.0"])

        def add_service(registry):
            registry["services"]["pgmeta"] = entry("supabase/pgmeta", "v0.1.0")

        self.set_upstream("supabase/pgmeta", ["v0.2.0", "v0.1.0"])
        self.assert_selection(
            self.registry_with(add_service),
            ["pgmeta\tv0.1.0", "pgmeta\tv0.2.0"],
        )

        def remove_service(registry):
            del registry["services"]["mailpit"]

        # A removed service is not validated: nothing remains to build.
        self.assert_nothing_selected(self.registry_with(remove_service))

    def test_registry_formatting_only_change_selects_nothing(self):
        self.assert_nothing_selected(
            {REGISTRY: json.dumps(BASE_REGISTRY, separators=(",", ":")) + "\n"}
        )

    def test_registry_change_outside_services_selects_everything(self):
        def add_top_level_key(registry):
            registry["schema"] = 2

        self.assert_selection(
            self.registry_with(add_top_level_key), AUTH + REALTIME + MAILPIT
        )

    def test_registry_missing_at_base_selects_every_service(self):
        # root_commit predates the registry file.
        head = self.head_with({})
        result = self.select(self.root_commit, head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout), include(*(AUTH + REALTIME + MAILPIT))
        )

    def test_shared_workflows_select_every_service(self):
        everything = AUTH + REALTIME + MAILPIT
        self.assert_selection({".github/workflows/service-release.yml": "changed\n"}, everything)
        self.assert_selection(
            {".github/workflows/service-validation.yml": "changed\n"}, everything
        )

    def test_shared_and_unclassified_paths_select_every_service(self):
        everything = AUTH + REALTIME + MAILPIT
        for path in (
            "scripts/foo.sh",
            "scripts/new-helper.sh",
            "nix/x.nix",
            "flake.nix",
            "flake.lock",
            ".gitmodules",
            ".dockerignore",
            ".bun-version",
            "weird/unclassified.txt",
        ):
            with self.subTest(path=path):
                result = self.assert_selection({path: "changed\n"}, everything)
                self.assertIn(f"{path} -> all services", result.stderr)

    def test_ignored_paths_do_not_narrow_a_service_selection(self):
        self.assert_selection(
            {
                "README.md": "changed\n",
                "scripts/test-foo.sh": "changed\n",
                "services/auth/build.sh": "changed\n",
            },
            AUTH,
        )

    def test_poller_failure_fails_the_selection(self):
        (self.upstream / "supabase_auth").unlink()
        head = self.head_with({"services/auth/build.sh": "changed\n"})
        result = self.select(self.base, head)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_poller_is_read_only(self):
        self.assert_selection({"services/auth/build.sh": "changed\n"}, AUTH)
        calls = self.trace.read_text(encoding="utf-8").splitlines()
        self.assertTrue(calls)
        self.assertTrue(all(call.startswith("api ") for call in calls), calls)

    def test_usage_error_without_revisions(self):
        result = subprocess.run(
            [str(SELECTOR)], cwd=self.repo, text=True, capture_output=True, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
PY
