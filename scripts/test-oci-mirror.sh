#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import hashlib
import json
import os
import pathlib
import shutil
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


def descriptor(value, *, platform=None, annotations=None, media_type=None):
    item = {
        "mediaType": media_type or "application/vnd.oci.image.manifest.v1+json",
        "digest": value,
        "size": 123,
    }
    if platform is not None:
        item["platform"] = platform
    if annotations is not None:
        item["annotations"] = annotations
    return item


def fixture_index(
    *, include_arm=True, duplicate_amd64=False, media_type=None, child_media_type=None, attest=True
):
    manifests = [
        descriptor(
            "sha256:" + "f" * 64,
            platform={"architecture": "amd64", "os": "linux"},
            media_type=child_media_type,
        )
    ]
    if include_arm:
        manifests.append(
            descriptor(
                "sha256:" + "6" * 64,
                platform={"architecture": "arm64", "os": "linux"},
                media_type=child_media_type,
            )
        )
    if duplicate_amd64:
        manifests.append(
            descriptor(
                "sha256:" + "e" * 64,
                platform={"architecture": "amd64", "os": "linux"},
                media_type=child_media_type,
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
                media_type=child_media_type,
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
                    "release_tag": "v1.2.3",
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

    def mirror_repo(self, *, custom=False):
        repo = self.directory / ("custom-repo" if custom else "default-repo")
        scripts = repo / "scripts"
        scripts.mkdir(parents=True)
        for name in ("lib.sh", "mirror-upstream-image.sh", "verify-oci-mirror.py", "upstream-release.py"):
            shutil.copy2(ROOT_DIR / "scripts" / name, scripts / name)
        smoke = scripts / "smoke.sh"
        smoke.write_text(
            "#!/bin/sh\n"
            '[ "$2" = --image ]\n'
            '[ -d "${DOCKER_CONFIG-}" ] && [ -z "$(ls -A "$DOCKER_CONFIG")" ]\n'
            'printf "default-smoke\\t%s\\t%s\\t%s\\n" "$1" "$3" "$DOCKER_CONFIG" >> "$FAKE_TRACE"\n',
            encoding="utf-8",
        )
        smoke.chmod(0o755)
        for service in ("mailpit", "vector", "imgproxy"):
            service_dir = repo / "services" / service
            service_dir.mkdir(parents=True)
            shutil.copy2(ROOT_DIR / "services" / service / "recipe.env", service_dir / "recipe.env")
            if service == "imgproxy":
                smoke = service_dir / "smoke.sh"
                smoke.write_text(
                    "#!/bin/sh\n"
                    '[ -n "$IMAGE" ]\n'
                    '[ -d "${DOCKER_CONFIG-}" ] && [ -z "$(ls -A "$DOCKER_CONFIG")" ]\n'
                    'printf "default-smoke\\t%s\\t%s\\t%s\\n" "imgproxy" "$IMAGE" "$DOCKER_CONFIG" >> "$FAKE_TRACE"\n',
                    encoding="utf-8",
                )
                smoke.chmod(0o755)
        if custom:
            custom_smoke = repo / "services" / "mailpit" / "custom-smoke.sh"
            custom_smoke.write_text(
                "#!/bin/sh\n"
                '[ -n "$IMAGE" ]\n'
                '[ -d "${DOCKER_CONFIG-}" ] && [ -z "$(ls -A "$DOCKER_CONFIG")" ]\n'
                'printf "custom-smoke\\t%s\\t%s\\n" "$IMAGE" "$DOCKER_CONFIG" >> "$FAKE_TRACE"\n',
                encoding="utf-8",
            )
            custom_smoke.chmod(0o755)
            recipe = repo / "services" / "mailpit" / "recipe.env"
            with recipe.open("a", encoding="utf-8") as stream:
                stream.write('MIRROR_SMOKE_SCRIPT="services/mailpit/custom-smoke.sh"\n')
        return repo

    def run_recipe_mirror(self, service, repo):
        fake_bin = self.directory / f"fake-{service}-bin"
        fake_bin.mkdir()
        trace = self.directory / f"{service}-mirror-trace"
        fake_regctl = fake_bin / "regctl"
        fake_regctl.write_text(
            "#!/bin/sh\n"
            'empty=no; [ -d "${REGCTL_CONFIG-}" ] && [ -z "$(ls -A "$REGCTL_CONFIG")" ] && empty=yes\n'
            'printf "regctl\\t%s\\t%s\\n" "$*" "$empty" >> "$FAKE_TRACE"\n'
            'if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "$FAKE_DIGEST"; exit 0; fi\n'
            'if [ "$1" = image ] && [ "$2" = manifest ]; then cat "$FAKE_RAW"; exit 0; fi\n'
            'if [ "$1" = image ] && [ "$2" = copy ]; then exit 0; fi\n'
            'if [ "$1" = artifact ] && [ "$2" = tree ]; then printf "%s\\n" "$FAKE_DIGEST"; exit 0; fi\n'
            "exit 1\n",
            encoding="utf-8",
        )
        fake_regctl.chmod(0o755)
        fake_docker = fake_bin / "docker"
        fake_docker.write_text(
            "#!/bin/sh\n"
            'empty=no; [ -d "${DOCKER_CONFIG-}" ] && [ -z "$(ls -A "$DOCKER_CONFIG")" ] && empty=yes\n'
            'printf "docker\\t%s\\t%s\\n" "$*" "$empty" >> "$FAKE_TRACE"\n'
            "[ \"$1\" = pull ]\n",
            encoding="utf-8",
        )
        fake_docker.chmod(0o755)
        destination = f"example.invalid/{service}"
        output = self.directory / f"{service}-provenance.json"
        result = subprocess.run(
            [str(repo / "scripts" / "mirror-upstream-image.sh"), service, "v1.2.3", destination, str(output)],
            cwd=repo,
            text=True,
            capture_output=True,
            env={
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "UPSTREAM_ASSETS_FILE": str(self.policy_path),
                "FAKE_TRACE": str(trace),
                "FAKE_DIGEST": digest(self.source_path.read_bytes()),
                "FAKE_RAW": str(self.source_path),
            },
            check=False,
        )
        return result, trace, output

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

    def test_missing_and_duplicate_platforms_fail(self):
        for index in (
            fixture_index(include_arm=False),
            fixture_index(duplicate_amd64=True),
        ):
            result = self.run_verify(source=index)
            self.assertNotEqual(result.returncode, 0)

    def test_docker_manifest_list_family_is_accepted(self):
        index = fixture_index(
            media_type="application/vnd.docker.distribution.manifest.list.v2+json",
            child_media_type="application/vnd.docker.distribution.manifest.v2+json",
        )
        source = raw(index)
        self.source_path.write_bytes(source)
        self.dest_path.write_bytes(source)
        policy = json.loads(self.policy_path.read_text(encoding="utf-8"))
        policy["versions"]["v1.2.3"]["image"]["index_digest"] = digest(source)
        self.policy_path.write_text(json.dumps(policy), encoding="utf-8")
        result = self.run_verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_mismatched_docker_child_media_type_fails(self):
        index = fixture_index(
            media_type="application/vnd.docker.distribution.manifest.list.v2+json"
        )
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

    def test_mirror_recipes_execute_default_smoke_route(self):
        repo = self.mirror_repo()
        for service in ("mailpit", "vector", "imgproxy"):
            result, trace, output = self.run_recipe_mirror(service, repo)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(output.is_file())
            lines = trace.read_text(encoding="utf-8").splitlines()
            smoke = [line.split("\t") for line in lines if line.startswith("default-smoke\t")]
            self.assertEqual(smoke[0][1:3], [service, f"example.invalid/{service}:v1.2.3"])
            self.assertTrue(smoke[0][3])
            pulls = [line.split("\t") for line in lines if line.startswith("docker\t")]
            self.assertTrue(any("pull example.invalid/" + service + ":v1.2.3" in line[1] and line[2] == "yes" for line in pulls))
            regctl = [line.split("\t") for line in lines if line.startswith("regctl\t")]
            self.assertTrue(any("image digest" in line[1] and line[2] == "yes" for line in regctl))

    def test_recipe_declared_custom_smoke_receives_image_and_anonymous_config(self):
        repo = self.mirror_repo(custom=True)
        result, trace, output = self.run_recipe_mirror("mailpit", repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_file())
        lines = trace.read_text(encoding="utf-8").splitlines()
        custom = [line.split("\t") for line in lines if line.startswith("custom-smoke\t")]
        self.assertEqual(custom[0][1], "example.invalid/mailpit:v1.2.3")
        self.assertTrue(custom[0][2])
        pulls = [line.split("\t") for line in lines if line.startswith("docker\t")]
        self.assertTrue(any(line[2] == "yes" for line in pulls))

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
