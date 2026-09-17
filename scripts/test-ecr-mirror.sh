#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT_DIR = pathlib.Path(sys.argv[1])
sys.argv[1:] = []
SCRIPT = ROOT_DIR / "scripts" / "ecr-mirror.sh"
DIGEST = "sha256:" + "a" * 64


def run(*args, env=None):
    return subprocess.run(
        [str(SCRIPT), *args],
        capture_output=True,
        text=True,
        cwd=ROOT_DIR,
        env={"PATH": "/usr/bin:/bin", **(env or {})},
    )


class EcrMirrorContract(unittest.TestCase):
    def test_payload_renders_dispatch_request(self):
        result = run("payload", "postgrest", "v16.2", DIGEST)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["event_type"], "mirror-slim-image")
        self.assertEqual(
            payload["client_payload"],
            {
                "service": "postgrest",
                "version": "v16.2",
                "source": "ghcr.io/supabase/cli/postgrest:v16.2",
                "digest": DIGEST,
                "destination": "public.ecr.aws/supabase/cli/postgrest:v16.2",
            },
        )

    def test_payload_honors_prefix_overrides(self):
        result = run(
            "payload",
            "auth",
            "v2.196.0",
            DIGEST,
            env={
                "MIRROR_EVENT_TYPE": "mirror-test",
                "SOURCE_IMAGE_PREFIX": "ghcr.io/example/src",
                "ECR_MIRROR_PREFIX": "public.ecr.aws/example/dst",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["event_type"], "mirror-test")
        self.assertEqual(
            payload["client_payload"]["source"], "ghcr.io/example/src/auth:v2.196.0"
        )
        self.assertEqual(
            payload["client_payload"]["destination"],
            "public.ecr.aws/example/dst/auth:v2.196.0",
        )

    def test_payload_rejects_unknown_service(self):
        result = run("payload", "kong", "v1.0.0", DIGEST)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown release service", result.stderr)

    def test_payload_rejects_disallowed_version(self):
        result = run("payload", "postgrest", "latest", DIGEST)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not an allowed release tag", result.stderr)

    def test_payload_rejects_malformed_digest(self):
        result = run("payload", "postgrest", "v16.2", "sha256:nope")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a sha256 image digest", result.stderr)

    def test_request_requires_token_when_destination_is_stale(self):
        with tempfile.TemporaryDirectory() as stub_dir:
            for stub in ("gh", "regctl"):
                stub_path = pathlib.Path(stub_dir) / stub
                stub_path.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
                stub_path.chmod(0o755)
            result = run(
                "request",
                "postgrest",
                "v16.2",
                DIGEST,
                env={"PATH": f"{stub_dir}:/usr/bin:/bin"},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MIRROR_DISPATCH_TOKEN is required", result.stderr)

    def test_request_is_noop_when_destination_matches(self):
        with tempfile.TemporaryDirectory() as stub_dir:
            stub_dir = pathlib.Path(stub_dir)
            fake_regctl = stub_dir / "regctl"
            fake_regctl.write_text(
                "#!/bin/sh\n"
                f'if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "{DIGEST}"; exit 0; fi\n'
                "exit 1\n",
                encoding="utf-8",
            )
            fake_regctl.chmod(0o755)
            fake_gh = stub_dir / "gh"
            fake_gh.write_text("#!/usr/bin/env bash\nexit 1\n", encoding="utf-8")
            fake_gh.chmod(0o755)
            result = run(
                "request",
                "postgrest",
                "v16.2",
                DIGEST,
                env={"PATH": f"{stub_dir}:/usr/bin:/bin"},
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("destination already matches", result.stdout)

    def test_destination_digest_uses_empty_task_local_configs(self):
        with tempfile.TemporaryDirectory() as stub_dir:
            stub_dir = pathlib.Path(stub_dir)
            trace = stub_dir / "regctl-trace"
            fake_regctl = stub_dir / "regctl"
            fake_regctl.write_text(
                "#!/bin/sh\n"
                "regctl_empty=no; docker_empty=no\n"
                '[ -d "${REGCTL_CONFIG-}" ] && [ -z "$(ls -A "$REGCTL_CONFIG")" ] && regctl_empty=yes\n'
                '[ -d "${DOCKER_CONFIG-}" ] && [ -z "$(ls -A "$DOCKER_CONFIG")" ] && docker_empty=yes\n'
                'printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$*" "${REGCTL_CONFIG-}" "${DOCKER_CONFIG-}" "$regctl_empty" "$docker_empty" >> "$FAKE_TRACE"\n'
                'n=0; [ -f "$FAKE_TRACE.count" ] && n=$(cat "$FAKE_TRACE.count")\n'
                'n=$((n + 1)); printf "%s\\n" "$n" > "$FAKE_TRACE.count"\n'
                f'if [ "$1" = image ] && [ "$2" = digest ] && [ "$n" -ge 2 ]; then printf "%s\\n" "{DIGEST}"; exit 0; fi\n'
                f'if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "sha256:{"b" * 64}"; exit 0; fi\n'
                "exit 1\n",
                encoding="utf-8",
            )
            fake_regctl.chmod(0o755)
            caller_regctl = stub_dir / "caller-regctl"
            caller_docker = stub_dir / "caller-docker"
            caller_regctl.mkdir()
            caller_docker.mkdir()
            result = run(
                "verify",
                "postgrest",
                "v16.2",
                DIGEST,
                env={
                    "PATH": f"{stub_dir}:/usr/bin:/bin",
                    "FAKE_TRACE": str(trace),
                    "REGCTL_CONFIG": str(caller_regctl),
                    "DOCKER_CONFIG": str(caller_docker),
                    "ECR_MIRROR_POLL_INTERVAL": "0",
                    "ECR_MIRROR_TIMEOUT": "30",
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            dest_lines = [
                line.split("\t")
                for line in trace.read_text(encoding="utf-8").splitlines()
                if "image digest public.ecr.aws/supabase/cli/postgrest:v16.2" in line
            ]
            self.assertGreaterEqual(len(dest_lines), 2)
            _, regctl_config, docker_config, regctl_empty, docker_empty = dest_lines[-1]
            self.assertEqual(dest_lines[0][1], dest_lines[1][1])
            self.assertNotEqual(regctl_config, str(caller_regctl))
            self.assertNotEqual(docker_config, str(caller_docker))
            self.assertEqual(regctl_empty, "yes")
            self.assertEqual(docker_empty, "yes")

    def test_sync_lists_published_tag_outside_current_pattern(self):
        stale = "sha256:" + "b" * 64
        with tempfile.TemporaryDirectory() as stub_dir:
            stub_dir = pathlib.Path(stub_dir)
            fake_gh = stub_dir / "gh"
            fake_gh.write_text(
                "#!/usr/bin/env bash\n"
                'cat <<\'EOF\'\n'
                '[[{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false}]]\n'
                "EOF\n",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)
            fake_regctl = stub_dir / "regctl"
            fake_regctl.write_text(
                "#!/bin/sh\n"
                f'if [ "$1" = manifest ] && [ "$2" = head ]; then printf "%s\\n" "{DIGEST}"; exit 0; fi\n'
                f'if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "{stale}"; exit 0; fi\n'
                "exit 1\n",
                encoding="utf-8",
            )
            fake_regctl.chmod(0o755)
            result = run(
                "sync",
                env={"PATH": f"{stub_dir}:/usr/bin:/bin"},
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("out of sync: postgres 15.14.1.159", result.stdout)
        self.assertNotIn("no published releases found", result.stderr)


unittest.main(verbosity=2)
PY
