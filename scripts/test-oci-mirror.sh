#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT_DIR = pathlib.Path(sys.argv[1])
sys.argv[1:] = []
SCRIPT = ROOT_DIR / "scripts" / "verify-oci-mirror.py"


def digest(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def descriptor(value, *, platform=None, annotations=None):
    item = {
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "digest": value,
        "size": 123,
    }
    if platform is not None:
        item["platform"] = platform
    if annotations is not None:
        item["annotations"] = annotations
    return item


def fixture_index(*, include_arm=True, duplicate_amd64=False, media_type=None, attest=True):
    manifests = [
        descriptor(
            "sha256:" + "f" * 64,
            platform={"architecture": "amd64", "os": "linux"},
        )
    ]
    if include_arm:
        manifests.append(
            descriptor(
                "sha256:" + "6" * 64,
                platform={"architecture": "arm64", "os": "linux"},
            )
        )
    if duplicate_amd64:
        manifests.append(
            descriptor(
                "sha256:" + "e" * 64,
                platform={"architecture": "amd64", "os": "linux"},
            )
        )
    if attest:
        manifests.append(
            descriptor(
                "sha256:" + "a" * 64,
                annotations={
                    "vnd.docker.reference.digest": "sha256:" + "f" * 64,
                    "vnd.docker.reference.type": "attestation-manifest",
                },
            )
        )
    return {
        "schemaVersion": 2,
        "mediaType": media_type or "application/vnd.oci.image.index.v1+json",
        "manifests": manifests,
    }


def raw(value):
    return json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"


class VerifyOciMirrorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.temp.name)
        source = raw(fixture_index())
        self.source_path = self.directory / "source.json"
        self.dest_path = self.directory / "dest.json"
        self.source_path.write_bytes(source)
        self.dest_path.write_bytes(source)
        policy = {
            "repository": "axllent/mailpit",
            "versions": {
                "v1.2.3": {
                    "assets": {
                        target: {
                            "name": f"mailpit-{target}.tar.gz",
                            "url": f"https://github.com/axllent/mailpit/releases/download/v1.2.3/mailpit-{target}.tar.gz",
                            "sha256": "0" * 64,
                        }
                        for target in ("darwin-arm64", "linux-amd64", "linux-arm64")
                    },
                    "image": {
                        "source": "docker.io/axllent/mailpit:v1.2.3",
                        "index_digest": digest(source),
                        "platforms": {
                            "linux/amd64": "sha256:" + "f" * 64,
                            "linux/arm64": "sha256:" + "6" * 64,
                        },
                    },
                }
            },
        }
        self.policy_path = self.directory / "policy.json"
        self.policy_path.write_text(json.dumps(policy), encoding="utf-8")
        self.output_path = self.directory / "provenance.json"

    def tearDown(self):
        self.temp.cleanup()

    def run_verify(self, source=None, destination=None):
        if source is not None:
            self.source_path.write_bytes(raw(source))
        if destination is not None:
            self.dest_path.write_bytes(raw(destination))
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(self.policy_path),
                "v1.2.3",
                str(self.source_path),
                str(self.dest_path),
                str(self.output_path),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_matching_index_and_platforms_write_deterministic_provenance(self):
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        provenance = json.loads(self.output_path.read_text(encoding="utf-8"))
        source_digest = digest(self.source_path.read_bytes())
        self.assertEqual(provenance["source_index_digest"], source_digest)
        self.assertEqual(provenance["destination_index_digest"], source_digest)
        self.assertEqual(
            provenance["platforms"],
            {
                "linux/amd64": "sha256:" + "f" * 64,
                "linux/arm64": "sha256:" + "6" * 64,
            },
        )
        first = self.output_path.read_bytes()
        self.assertEqual(self.run_verify().returncode, 0)
        self.assertEqual(first, self.output_path.read_bytes())

    def test_changed_index_or_platform_fails(self):
        changed = fixture_index()
        changed["manifests"][0]["size"] = 124
        result = self.run_verify(destination=changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("index digest", result.stderr)

        changed = fixture_index()
        changed["manifests"][0]["digest"] = "sha256:" + "1" * 64
        policy = json.loads(self.policy_path.read_text(encoding="utf-8"))
        policy["versions"]["v1.2.3"]["image"]["index_digest"] = digest(raw(changed))
        self.policy_path.write_text(json.dumps(policy), encoding="utf-8")
        result = self.run_verify(source=changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("platform linux/amd64", result.stderr)

    def test_missing_duplicate_and_unexpected_media_type_fail(self):
        for index in (
            fixture_index(include_arm=False),
            fixture_index(duplicate_amd64=True),
            fixture_index(media_type="application/vnd.docker.distribution.manifest.list.v2+json"),
        ):
            result = self.run_verify(source=index)
            self.assertNotEqual(result.returncode, 0)

    def test_lost_embedded_attestation_fails(self):
        result = self.run_verify(destination=fixture_index(attest=False))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("attestation", result.stderr)


if __name__ == "__main__":
    unittest.main()
PY

echo "OCI mirror tests passed"
