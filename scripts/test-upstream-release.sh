#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import copy
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT_DIR = pathlib.Path(sys.argv[1])
sys.argv[1:] = []
MODULE_PATH = ROOT_DIR / "scripts" / "upstream-release.py"
SPEC = importlib.util.spec_from_file_location("upstream_release", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {MODULE_PATH}")
upstream_release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(upstream_release)


VALID_POLICY = {
    "repository": "axllent/mailpit",
    "versions": {
        "v1.0.0": {
            "assets": {
                "darwin-arm64": {
                    "name": "mailpit-v1.0.0-darwin-arm64.tar.gz",
                    "url": "https://github.com/axllent/mailpit/releases/download/v1.0.0/mailpit-v1.0.0-darwin-arm64.tar.gz",
                    "sha256": "a" * 64,
                },
                "linux-amd64": {
                    "name": "mailpit-v1.0.0-linux-amd64.tar.gz",
                    "url": "https://github.com/axllent/mailpit/releases/download/v1.0.0/mailpit-v1.0.0-linux-amd64.tar.gz",
                    "sha256": "b" * 64,
                },
                "linux-arm64": {
                    "name": "mailpit-v1.0.0-linux-arm64.tar.gz",
                    "url": "https://github.com/axllent/mailpit/releases/download/v1.0.0/mailpit-v1.0.0-linux-arm64.tar.gz",
                    "sha256": "c" * 64,
                },
            },
            "image": {
                "source": "docker.io/axllent/mailpit:v1.0.0",
                "index_digest": "sha256:" + "d" * 64,
                "platforms": {
                    "linux/amd64": "sha256:" + "e" * 64,
                    "linux/arm64": "sha256:" + "f" * 64,
                },
            },
        }
    },
}


class UpstreamReleasePolicyTest(unittest.TestCase):
    def write_policy(self, policy):
        temporary = tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".json", delete=False)
        self.addCleanup(pathlib.Path(temporary.name).unlink)
        with temporary:
            json.dump(policy, temporary)
        return pathlib.Path(temporary.name)

    def assert_invalid(self, policy, message):
        with self.subTest(message=message):
            with self.assertRaises(ValueError):
                upstream_release.load_policy(self.write_policy(policy))

    def test_resolves_exact_asset_and_image_data(self):
        policy = upstream_release.load_policy(self.write_policy(VALID_POLICY))

        self.assertEqual(
            upstream_release.resolve_asset(policy, "v1.0.0", "linux-amd64"),
            {
                "name": "mailpit-v1.0.0-linux-amd64.tar.gz",
                "url": "https://github.com/axllent/mailpit/releases/download/v1.0.0/mailpit-v1.0.0-linux-amd64.tar.gz",
                "sha256": "b" * 64,
            },
        )
        self.assertEqual(
            upstream_release.resolve_image(policy, "v1.0.0"),
            {
                "source": "docker.io/axllent/mailpit:v1.0.0",
                "index_digest": "sha256:" + "d" * 64,
                "platforms": {
                    "linux/amd64": "sha256:" + "e" * 64,
                    "linux/arm64": "sha256:" + "f" * 64,
                },
            },
        )

    def test_rejects_unknown_version_and_target(self):
        policy = upstream_release.load_policy(self.write_policy(VALID_POLICY))

        with self.assertRaises(ValueError):
            upstream_release.resolve_asset(policy, "v9.9.9", "linux-amd64")
        with self.assertRaises(ValueError):
            upstream_release.resolve_asset(policy, "v1.0.0", "freebsd-amd64")

    def test_rejects_missing_target(self):
        policy = copy.deepcopy(VALID_POLICY)
        del policy["versions"]["v1.0.0"]["assets"]["linux-arm64"]
        self.assert_invalid(policy, "missing native target")

    def test_rejects_noncanonical_github_url(self):
        policy = copy.deepcopy(VALID_POLICY)
        policy["versions"]["v1.0.0"]["assets"]["linux-amd64"]["url"] = (
            "http://github.com/axllent/mailpit/releases/download/v1.0.0/"
            "mailpit-v1.0.0-linux-amd64.tar.gz"
        )
        self.assert_invalid(policy, "noncanonical GitHub URL")

    def test_rejects_malformed_digest(self):
        policy = copy.deepcopy(VALID_POLICY)
        policy["versions"]["v1.0.0"]["assets"]["linux-amd64"]["sha256"] = "not-a-digest"
        self.assert_invalid(policy, "malformed archive digest")

    def test_rejects_mismatched_url_components(self):
        policy = copy.deepcopy(VALID_POLICY)
        policy["versions"]["v1.0.0"]["assets"]["linux-amd64"]["url"] = (
            "https://github.com/axllent/mailpit/releases/download/v9.9.9/"
            "mailpit-v1.0.0-linux-amd64.tar.gz"
        )
        self.assert_invalid(policy, "mismatched release URL components")

    def test_rejects_missing_required_image_platforms(self):
        policy = copy.deepcopy(VALID_POLICY)
        del policy["versions"]["v1.0.0"]["image"]["platforms"]["linux/arm64"]
        self.assert_invalid(policy, "missing image platform")

    def test_rejects_unexpected_keys(self):
        policy = copy.deepcopy(VALID_POLICY)
        policy["unexpected"] = True
        self.assert_invalid(policy, "unexpected policy key")


if __name__ == "__main__":
    unittest.main()
PY

echo "upstream release policy tests passed"
