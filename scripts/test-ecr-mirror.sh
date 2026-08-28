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

    def test_unknown_subcommand_prints_usage(self):
        result = run("mirror-all")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)


unittest.main(verbosity=2)
PY
