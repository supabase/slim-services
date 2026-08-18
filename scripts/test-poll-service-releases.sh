#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import datetime
import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
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

    def run_poller(
        self,
        service="realtime",
        max_dispatches_per_service="1",
        max_active_releases="12",
        docker_hub_api_base=None,
    ):
        environment = {
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
        }
        if max_dispatches_per_service is not None:
            environment["POLL_MAX_DISPATCHES_PER_SERVICE"] = str(
                max_dispatches_per_service
            )
        if max_active_releases is not None:
            environment["POLL_MAX_ACTIVE_RELEASES"] = str(max_active_releases)
        if docker_hub_api_base is not None:
            environment["DOCKER_HUB_API_BASE"] = docker_hub_api_base

        return subprocess.run(
            [str(POLLER)],
            text=True,
            capture_output=True,
            env=environment,
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

    def test_dispatches_three_missing_releases_per_service_by_default(self):
        result = self.run_poller(
            max_dispatches_per_service=None,
            max_active_releases=None,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.0 -f force=false",
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.1 -f force=false",
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.2 -f force=false",
            ],
        )

    def test_global_capacity_counts_active_and_new_release_workflows(self):
        self.runs.write_text(
            json.dumps(
                [
                    {
                        "displayTitle": f"Release auth v1.0.{index}",
                        "status": "in_progress",
                        "conclusion": "",
                        "createdAt": "2999-01-01T00:00:00Z",
                        "updatedAt": "2999-01-01T00:00:00Z",
                    }
                    for index in range(10)
                ]
            ),
            encoding="utf-8",
        )

        result = self.run_poller(
            max_dispatches_per_service=None,
            max_active_releases=None,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.0 -f force=false",
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=realtime -f version=v2.128.1 -f force=false",
            ],
        )

    def test_global_capacity_stops_dispatch_when_twelve_releases_are_active(self):
        self.runs.write_text(
            json.dumps(
                [
                    {
                        "displayTitle": f"Release auth v1.0.{index}",
                        "status": "in_progress",
                        "conclusion": "",
                        "createdAt": "2999-01-01T00:00:00Z",
                        "updatedAt": "2999-01-01T00:00:00Z",
                    }
                    for index in range(12)
                ]
            ),
            encoding="utf-8",
        )

        result = self.run_poller(
            max_dispatches_per_service=None,
            max_active_releases=None,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.trace.exists())
        self.assertIn("global active release limit", result.stdout)

    def test_validation_rejects_dockerhub_source_ref_patterns_without_one_capture_group(self):
        config = json.loads(self.config.read_text(encoding="utf-8"))
        config["services"]["realtime"].update(
            {
                "release_source": "dockerhub",
                "image_repository": "supabase/realtime",
                "source_ref_tag_pattern": r"-sha-[0-9a-f]{7}$",
            }
        )
        self.config.write_text(json.dumps(config), encoding="utf-8")

        result = subprocess.run(
            [str(POLLER), "--validate-config"],
            text=True,
            capture_output=True,
            env={**os.environ, "SERVICE_RELEASE_CONFIG": str(self.config)},
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source_ref_tag_pattern", result.stderr)

    def test_postgres_discovers_only_published_docker_tags(self):
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

        class DockerHubHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps(
                    {
                        "count": 2,
                        "next": None,
                        "previous": None,
                        "results": [
                            {"name": "17.6.1.159"},
                            {"name": "17.6.1.777"},
                        ],
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DockerHubHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = self.run_poller(
                service="postgres",
                docker_hub_api_base=f"http://127.0.0.1:{server.server_port}/v2",
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.trace.read_text(encoding="utf-8").splitlines(),
            [
                "workflow run service-release.yml --repo supabase/slim-services "
                "--ref main -f service=postgres -f version=17.6.1.777 -f force=false"
            ],
        )


if __name__ == "__main__":
    unittest.main()
PY
