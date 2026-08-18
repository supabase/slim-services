#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import datetime
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(sys.argv.pop(1))
POLLER = ROOT / "scripts" / "poll-service-releases.sh"


class ReleasePollerTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="release-poller-test.")
        self.directory = pathlib.Path(self.temporary_directory.name)
        self.fake_bin = self.directory / "bin"
        self.fake_bin.mkdir()
        self.trace = self.directory / "gh-trace"
        self.upstream_releases = self.directory / "upstream-releases"
        self.upstream_releases.write_text(
            "v2.129.0\nv2.128.3\nv2.128.2\nv2.128.1\nv2.128.0\n",
            encoding="utf-8",
        )
        self.runs = self.directory / "runs.json"
        self.runs.write_text("[]\n", encoding="utf-8")
        self.published = self.directory / "published"
        self.published.write_text("", encoding="utf-8")
        self.config = self.directory / "service-release-sources.json"
        self.config.write_text(
            json.dumps(
                {
                    "services": {
                        "realtime": {
                            "repository": "supabase/realtime",
                            "tag_pattern": r"^v[0-9]+\.[0-9]+\.[0-9]+$",
                            "release_floor": "v2.128.0",
                            "poll": True,
                        }
                    }
                }
            ),
            encoding="utf-8",
        )
        fake_gh = self.fake_bin / "gh"
        fake_gh.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "case \"$1\" in\n"
            "  api)\n"
            "    case \"$*\" in\n"
            "      *supabase/slim-services/releases*) cat \"$FAKE_PUBLISHED_RELEASES\" ;;\n"
            "      *) cat \"$FAKE_UPSTREAM_RELEASES\" ;;\n"
            "    esac\n"
            "    ;;\n"
            "  run)\n"
            "    cat \"$FAKE_RUNS_JSON\"\n"
            "    ;;\n"
            "  workflow)\n"
            "    printf '%s\\n' \"$*\" >> \"$FAKE_GH_TRACE\"\n"
            "    ;;\n"
            "  *)\n"
            "    printf 'unexpected gh invocation: %s\\n' \"$*\" >&2\n"
            "    exit 2\n"
            "    ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def run_poller(self, service="realtime"):
        return subprocess.run(
            [str(POLLER)],
            text=True,
            capture_output=True,
            env={
                **os.environ,
                "PATH": f"{self.fake_bin}:{os.environ['PATH']}",
                "GH_TOKEN": "test-token",
                "POLL_SERVICE": service,
                "SERVICE_RELEASE_REF": "main",
                "SERVICE_RELEASE_CONFIG": str(self.config),
                "FAKE_GH_TRACE": str(self.trace),
                "FAKE_PUBLISHED_RELEASES": str(self.published),
                "FAKE_RUNS_JSON": str(self.runs),
                "FAKE_UPSTREAM_RELEASES": str(self.upstream_releases),
            },
            check=False,
        )

    def test_validation_requires_a_matching_floor_for_polled_services(self):
        config = json.loads(self.config.read_text(encoding="utf-8"))
        del config["services"]["realtime"]["release_floor"]
        self.config.write_text(json.dumps(config), encoding="utf-8")

        result = subprocess.run(
            [str(POLLER), "--validate-config"],
            text=True,
            capture_output=True,
            env={**os.environ, "SERVICE_RELEASE_CONFIG": str(self.config)},
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release_floor", result.stderr)

    def test_dispatches_oldest_missing_release_instead_of_only_latest(self):
        result = self.run_poller()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.0 -f force=false"
            ],
        )

    def test_recent_unsuccessful_completion_cools_from_updated_time(self):
        self.runs.write_text(
            json.dumps(
                [
                    {
                        "displayTitle": "Release realtime v2.128.0",
                        "status": "completed",
                        "conclusion": "failure",
                        "createdAt": "2000-01-01T00:00:00Z",
                        "updatedAt": "2999-01-01T00:00:00Z",
                    }
                ]
            ),
            encoding="utf-8",
        )

        result = self.run_poller()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.1 -f force=false"
            ],
        )

    def test_recent_success_waits_for_release_publication_without_long_cooldown(self):
        self.runs.write_text(
            json.dumps(
                [
                    {
                        "displayTitle": "Release realtime v2.128.0",
                        "status": "completed",
                        "conclusion": "success",
                        "createdAt": "2000-01-01T00:00:00Z",
                        "updatedAt": "2999-01-01T00:00:00Z",
                    }
                ]
            ),
            encoding="utf-8",
        )

        result = self.run_poller()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.1 -f force=false"
            ],
        )

    def test_success_without_release_is_retryable_after_publication_grace(self):
        one_hour_ago = (
            datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)
        ).isoformat().replace("+00:00", "Z")
        self.runs.write_text(
            json.dumps(
                [
                    {
                        "displayTitle": "Release realtime v2.128.0",
                        "status": "completed",
                        "conclusion": "success",
                        "createdAt": "2000-01-01T00:00:00Z",
                        "updatedAt": one_hour_ago,
                    }
                ]
            ),
            encoding="utf-8",
        )

        result = self.run_poller()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.0 -f force=false"
            ],
        )

    def test_unsuccessful_run_is_retryable_after_six_hours(self):
        seven_hours_ago = (
            datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=7)
        ).isoformat().replace("+00:00", "Z")
        self.runs.write_text(
            json.dumps(
                [
                    {
                        "displayTitle": "Release realtime v2.128.0",
                        "status": "completed",
                        "conclusion": "timed_out",
                        "createdAt": "2000-01-01T00:00:00Z",
                        "updatedAt": seven_hours_ago,
                    }
                ]
            ),
            encoding="utf-8",
        )

        result = self.run_poller()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.0 -f force=false"
            ],
        )

    def test_reconciles_by_version_when_upstream_feed_is_not_version_ordered(self):
        self.upstream_releases.write_text(
            "v2.129.0\nv2.128.0\nv2.128.3\nv2.128.2\nv2.128.1\n",
            encoding="utf-8",
        )
        self.published.write_text("realtime-v2.128.0\n", encoding="utf-8")

        result = self.run_poller()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.1 -f force=false"
            ],
        )

    def test_postgres_ignores_numeric_ami_test_suffix(self):
        production_config = json.loads(
            (ROOT / ".github" / "service-release-sources.json").read_text(
                encoding="utf-8"
            )
        )
        self.config.write_text(
            json.dumps(
                {
                    "services": {
                        "postgres": production_config["services"]["postgres"]
                    }
                }
            ),
            encoding="utf-8",
        )
        self.upstream_releases.write_text(
            "17.10.1.001\n17.6.1.15799999\n17.6.1.159\n",
            encoding="utf-8",
        )
        self.published.write_text("postgres-17.6.1.159\n", encoding="utf-8")

        result = self.run_poller(service="postgres")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=postgres -f version=17.10.1.001 -f force=false"
            ],
        )


if __name__ == "__main__":
    unittest.main()
PY
