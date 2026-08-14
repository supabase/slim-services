#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT_DIR = pathlib.Path(sys.argv[1])
sys.argv[1:] = []
SCRIPT = ROOT_DIR / "scripts" / "verify-oci-mirror.py"
MIRROR_SCRIPT = ROOT_DIR / "scripts" / "mirror-upstream-image.sh"


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

    def test_anonymous_regctl_digest_uses_empty_task_local_configs(self):
        fake_bin = self.directory / "fake-bin"
        fake_bin.mkdir()
        trace = self.directory / "regctl-trace"
        fake_regctl = fake_bin / "regctl"
        fake_regctl.write_text(
            "#!/bin/sh\n"
            'regctl_empty=no; docker_empty=no\n'
            '[ -d "${REGCTL_CONFIG-}" ] && [ -z "$(ls -A "$REGCTL_CONFIG")" ] && regctl_empty=yes\n'
            '[ -d "${DOCKER_CONFIG-}" ] && [ -z "$(ls -A "$DOCKER_CONFIG")" ] && docker_empty=yes\n'
            'printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$*" "${REGCTL_CONFIG-}" "${DOCKER_CONFIG-}" "$regctl_empty" "$docker_empty" >> "$FAKE_TRACE"\n'
            'if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "$FAKE_DIGEST"; exit 0; fi\n'
            'if [ "$1" = image ] && [ "$2" = manifest ]; then cat "$FAKE_RAW"; exit 0; fi\n'
            'if [ "$1" = image ] && [ "$2" = copy ]; then exit 0; fi\n'
            'if [ "$1" = artifact ] && [ "$2" = tree ]; then printf "%s\\n" "$FAKE_DIGEST"; exit 0; fi\n'
            'exit 1\n',
            encoding="utf-8",
        )
        fake_regctl.chmod(0o755)
        caller_regctl = self.directory / "caller-regctl"
        caller_docker = self.directory / "caller-docker"
        caller_regctl.mkdir()
        caller_docker.mkdir()
        result = subprocess.run(
            ["bash", str(MIRROR_SCRIPT), "auth", "v1.2.3", "example.invalid/mailpit", str(self.output_path)],
            text=True,
            capture_output=True,
            env={
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "UPSTREAM_ASSETS_FILE": str(self.policy_path),
                "FAKE_TRACE": str(trace),
                "FAKE_DIGEST": digest(self.source_path.read_bytes()),
                "FAKE_RAW": str(self.source_path),
                "REGCTL_CONFIG": str(caller_regctl),
                "DOCKER_CONFIG": str(caller_docker),
            },
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        anonymous_lines = [
            line.split("\t")
            for line in trace.read_text(encoding="utf-8").splitlines()
            if "image digest example.invalid/mailpit:v1.2.3" in line
        ]
        self.assertTrue(anonymous_lines)
        _, regctl_config, docker_config, regctl_empty, docker_empty = anonymous_lines[-1]
        self.assertNotEqual(regctl_config, str(caller_regctl))
        self.assertNotEqual(docker_config, str(caller_docker))
        self.assertEqual(regctl_empty, "yes")
        self.assertEqual(docker_empty, "yes")
        tree_lines = [
            line for line in trace.read_text(encoding="utf-8").splitlines() if "artifact tree" in line
        ]
        self.assertEqual(len(tree_lines), 2, tree_lines)
        self.assertTrue(all("artifact tree --digest-tags" in line for line in tree_lines), tree_lines)

    def test_vector_release_policy_and_manual_dispatch_route(self):
        config_path = ROOT_DIR / ".github" / "service-release-sources.json"
        workflow_path = ROOT_DIR / ".github" / "workflows" / "service-release.yml"
        artifacts_workflow_path = ROOT_DIR / ".github" / "workflows" / "service-artifacts.yml"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        vector = config["services"]["vector"]
        self.assertEqual(vector["repository"], "vectordotdev/vector")
        self.assertEqual(vector["artifact_source"], "upstream-archive")
        self.assertEqual(vector["image_release"], "mirror")
        self.assertEqual(vector["image_repository"], "timberio/vector")
        self.assertEqual(vector["tag_pattern"], r"^[0-9]+\.[0-9]+\.[0-9]+$")
        self.assertFalse(vector["poll"])

        workflow = workflow_path.read_text(encoding="utf-8")
        self.assertIn("          - vector\n", workflow)
        self.assertIn(
            "            auth|postgrest|realtime|pooler|analytics|storage|edge-runtime|studio|pgmeta|postgres|mailpit|vector) ;;",
            workflow,
        )
        self.assertIn("upstream-release.py release-tag", workflow)
        self.assertIn('release_tag="$SERVICE-$VERSION"', workflow)
        self.assertIn(
            "default: auth postgrest realtime pooler analytics storage edge-runtime studio pgmeta postgres mailpit vector",
            artifacts_workflow_path.read_text(encoding="utf-8"),
        )

    def test_mirror_smoke_routing_is_recipe_driven_and_keeps_mailpit(self):
        mirror_script = MIRROR_SCRIPT.read_text(encoding="utf-8")
        vector_recipe = (ROOT_DIR / "services" / "vector" / "recipe.env").read_text(encoding="utf-8")
        mailpit_recipe = (ROOT_DIR / "services" / "mailpit" / "recipe.env").read_text(encoding="utf-8")

        self.assertIn('IMAGE_RELEASE_MODE="mirror"', vector_recipe)
        self.assertIn('IMAGE_RELEASE_MODE="mirror"', mailpit_recipe)
        self.assertIn("IMAGE_RELEASE_MODE", mirror_script)
        self.assertIn('"$ROOT_DIR/scripts/smoke.sh" "$service" --image "$destination_ref"', mirror_script)
        self.assertNotIn('if [[ "$service" == "mailpit" ]]', mirror_script)

    def test_vector_is_skipped_by_the_release_poller(self):
        fake_bin = self.directory / "fake-gh-bin"
        fake_bin.mkdir()
        fake_gh = fake_bin / "gh"
        fake_gh.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >> "$FAKE_GH_TRACE"\n'
            "exit 1\n",
            encoding="utf-8",
        )
        fake_gh.chmod(0o755)
        trace = self.directory / "gh-trace"
        result = subprocess.run(
            [str(ROOT_DIR / "scripts" / "poll-service-releases.sh")],
            text=True,
            capture_output=True,
            env={
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "GH_TOKEN": "test-token",
                "POLL_SERVICE": "vector",
                "POLL_DRY_RUN": "1",
                "SERVICE_RELEASE_CONFIG": str(ROOT_DIR / ".github" / "service-release-sources.json"),
                "FAKE_GH_TRACE": str(trace),
            },
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(trace.exists(), trace.read_text(encoding="utf-8") if trace.exists() else "")


if __name__ == "__main__":
    unittest.main()
PY

echo "OCI mirror tests passed"
