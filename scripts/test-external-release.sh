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

ROOT_DIR = pathlib.Path(sys.argv[1])
RESOLVER = ROOT_DIR / "scripts" / "resolve-external-release.sh"


class ExternalReleaseIntegrationTest:
    version = "0.99.0"
    release_tag = "v0.99.0"
    commit = "a" * 40
    index_digest = "sha256:" + "1" * 64
    platform_digests = {
        "linux/amd64": "sha256:" + "2" * 64,
        "linux/arm64": "sha256:" + "3" * 64,
    }

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.trace = self.root / "trace"
        self.archive = self.root / "archive.tar.gz"
        self.archive.write_bytes(b"controlled source archive\n")
        self.archive_sha256 = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.default_assets = [
            {
                "name": "mailpit-linux-amd64.tar.gz",
                "state": "uploaded",
                "browser_download_url": "https://github.com/acme/mailpit/releases/download/v0.99.0/mailpit-linux-amd64.tar.gz",
                "digest": "sha256:" + "a" * 64,
            },
            {
                "name": "mailpit-linux-arm64.tar.gz",
                "state": "uploaded",
                "browser_download_url": "https://github.com/acme/mailpit/releases/download/v0.99.0/mailpit-linux-arm64.tar.gz",
                "digest": "sha256:" + "b" * 64,
            },
            {
                "name": "mailpit-darwin-arm64.tar.gz",
                "state": "uploaded",
                "browser_download_url": "https://github.com/acme/mailpit/releases/download/v0.99.0/mailpit-darwin-arm64.tar.gz",
                "digest": "sha256:" + "c" * 64,
            },
        ]
        self.write_fakes()

    def close(self):
        self.tmp.cleanup()

    def write_executable(self, name, body):
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def write_fakes(self):
        self.write_executable(
            "gh",
            r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
trace = Path(os.environ["FAKE_TRACE"])
trace.open("a", encoding="utf-8").write("gh " + " ".join(sys.argv[1:]) + "\n")
if len(sys.argv) != 3 or sys.argv[1] != "api":
    raise SystemExit("unexpected gh arguments: " + " ".join(sys.argv[1:]))
endpoint = sys.argv[2]
repo = os.environ["FAKE_GITHUB_REPO"]
release_tag = os.environ["FAKE_RELEASE_TAG"]
if endpoint == f"repos/{repo}/releases/tags/{release_tag}":
    print(json.dumps({
        "tag_name": release_tag,
        "draft": False,
        "prerelease": False,
        "assets": json.loads(os.environ["FAKE_RELEASE_ASSETS"]),
    }))
elif endpoint == f"repos/{repo}/git/ref/tags/{release_tag}":
    print(json.dumps({"object": {"type": os.environ["FAKE_REF_TYPE"], "sha": os.environ["FAKE_REF_SHA"]}}))
elif endpoint == f"repos/{repo}/git/tags/{os.environ['FAKE_REF_SHA']}":
    print(json.dumps({"object": {"type": os.environ["FAKE_TAG_TYPE"], "sha": os.environ["FAKE_TAG_SHA"]}}))
else:
    raise SystemExit("unexpected gh endpoint: " + endpoint)
''',
        )
        self.write_executable(
            "regctl",
            r'''#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
source = __import__("os").environ["FAKE_OCI_SOURCE"]
if args == ["image", "digest", source]:
    print("sha256:" + "1" * 64)
elif args == ["image", "manifest", "--format", "raw-body", source + "@sha256:" + "1" * 64]:
    media_type = __import__("os").environ["FAKE_INDEX_MEDIA_TYPE"]
    child_media_type = __import__("os").environ["FAKE_CHILD_MEDIA_TYPE"]
    schema_version = int(__import__("os").environ.get("FAKE_SCHEMA_VERSION", "2"))
    print(json.dumps({
        "schemaVersion": schema_version,
        "mediaType": media_type,
        "manifests": [
            {"mediaType": child_media_type, "digest": "sha256:" + "2" * 64,
             "platform": {"os": "linux", "architecture": "amd64"}},
            {"mediaType": child_media_type, "digest": "sha256:" + "3" * 64,
             "platform": {"os": "linux", "architecture": "arm64"}},
        ],
    }))
else:
    raise SystemExit("unexpected regctl arguments: " + " ".join(args))
''',
        )
        self.write_executable(
            "curl",
            r'''#!/usr/bin/env python3
import os, pathlib, shutil, sys
if sys.argv[1] != "-fsSL" or sys.argv[2] != os.environ["FAKE_SOURCE_URL"] or sys.argv[3] != "-o" or len(sys.argv) != 5:
    raise SystemExit("unexpected curl arguments: " + " ".join(sys.argv[1:]))
output = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
shutil.copyfile(os.environ["FAKE_ARCHIVE"], output)
''',
        )
        self.write_executable(
            "nix",
            r'''#!/usr/bin/env python3
import json
import os, sys
if sys.argv[1:] != ["store", "prefetch-file", "--json", "--unpack", os.environ["FAKE_SOURCE_URL"]]:
    raise SystemExit("unexpected nix arguments: " + " ".join(sys.argv[1:]))
print(json.dumps({"hash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}))
''',
        )

    def descriptor(
        self,
        artifact_type="release-assets",
        repository="acme/mailpit",
        release_tag_template="v{version}",
        oci_repository="docker.io/acme/mailpit",
        oci_tag_template="{version}",
        asset_templates=None,
    ):
        artifact = {"type": artifact_type}
        if artifact_type == "release-assets":
            templates = asset_templates or {
                "darwin-arm64": "mailpit-darwin-arm64.tar.gz",
                "linux-amd64": "mailpit-linux-amd64.tar.gz",
                "linux-arm64": "mailpit-linux-arm64.tar.gz",
            }
            artifact["targets"] = {
                target: {"name_template": template}
                for target, template in templates.items()
            }
        return {
            "github": {
                "repository": repository,
                "release_tag_template": release_tag_template,
                "artifact": artifact,
            },
            "oci": {
                "repository": oci_repository,
                "tag_template": oci_tag_template,
                "required_platforms": ["linux/amd64", "linux/arm64"],
            },
        }

    def run(self, descriptor=None, version=None, hook=None, env=None):
        descriptor_path = self.root / "descriptor.json"
        descriptor_path.write_text(json.dumps(descriptor or self.descriptor()), encoding="utf-8")
        output = self.root / "snapshot.json"
        command = [str(RESOLVER), str(descriptor_path), version or self.version, str(output)]
        if hook:
            command.append(str(hook))
        merged = os.environ.copy()
        merged.update({
            "PATH": f"{self.bin}:{merged['PATH']}",
            "FAKE_TRACE": str(self.trace),
            "FAKE_ARCHIVE": str(self.archive),
            "FAKE_GITHUB_REPO": "acme/mailpit",
            "FAKE_RELEASE_TAG": "v0.99.0",
            "FAKE_SOURCE_URL": "https://github.com/acme/mailpit/archive/" + self.commit + ".tar.gz",
            "FAKE_OCI_SOURCE": "docker.io/acme/mailpit:0.99.0",
            "FAKE_RELEASE_ASSETS": json.dumps(self.default_assets),
            "FAKE_REF_TYPE": "tag",
            "FAKE_REF_SHA": "b" * 40,
            "FAKE_TAG_TYPE": "commit",
            "FAKE_TAG_SHA": self.commit,
            "FAKE_INDEX_MEDIA_TYPE": "application/vnd.oci.image.index.v1+json",
            "FAKE_CHILD_MEDIA_TYPE": "application/vnd.oci.image.manifest.v1+json",
        })
        if env:
            merged.update(env)
        return subprocess.run(command, cwd=ROOT_DIR, text=True, capture_output=True, env=merged), output

    def run_with_fake_mutation(self, name, old, new, descriptor=None):
        path = self.bin / name
        original = path.read_text(encoding="utf-8")
        assert old in original, f"fixture mutation anchor missing: {old!r}"
        path.write_text(original.replace(old, new, 1), encoding="utf-8")
        try:
            return self.run(descriptor)
        finally:
            path.write_text(original, encoding="utf-8")

    def run_with_assets(self, assets, descriptor=None):
        return self.run(
            descriptor,
            env={"FAKE_RELEASE_ASSETS": json.dumps(assets)},
        )

    def run_with_oci(self, index_media_type=None, child_media_type=None, schema_version=None, descriptor=None):
        env = {}
        if index_media_type is not None:
            env["FAKE_INDEX_MEDIA_TYPE"] = index_media_type
        if child_media_type is not None:
            env["FAKE_CHILD_MEDIA_TYPE"] = child_media_type
        if schema_version is not None:
            env["FAKE_SCHEMA_VERSION"] = str(schema_version)
        return self.run(descriptor, env=env)

    def run_shape(self, version, descriptor, release_tag, repository, oci_source, hook=None, **extra):
        env = {
            "FAKE_GITHUB_REPO": repository,
            "FAKE_RELEASE_TAG": release_tag,
            "FAKE_SOURCE_URL": f"https://github.com/{repository}/archive/{self.commit}.tar.gz",
            "FAKE_OCI_SOURCE": oci_source,
            "FAKE_RELEASE_ASSETS": "[]",
        }
        env.update(extra)
        return self.run(descriptor, version=version, hook=hook, env=env)

    def run_release_shape(
        self, version, descriptor, release_tag, repository, oci_source, assets, **extra
    ):
        env = {
            "FAKE_GITHUB_REPO": repository,
            "FAKE_RELEASE_TAG": release_tag,
            "FAKE_SOURCE_URL": f"https://github.com/{repository}/archive/{self.commit}.tar.gz",
            "FAKE_OCI_SOURCE": oci_source,
            "FAKE_RELEASE_ASSETS": json.dumps(assets),
        }
        env.update(extra)
        return self.run(descriptor, version=version, env=env)

    def assets(self, repository, release_tag, names, digests):
        return [
            {
                "name": name,
                "state": "uploaded",
                "browser_download_url": f"https://github.com/{repository}/releases/download/{release_tag}/{name}",
                "digest": f"sha256:{digest}",
            }
            for name, digest in zip(names, digests)
        ]

    def test_resolves_assets_and_exact_image(self):
        result, output = self.run()
        assert result.returncode == 0, result.stderr
        snapshot = json.loads(output.read_text(encoding="utf-8"))
        record = snapshot["versions"][self.version]
        assert record["release_tag"] == self.release_tag
        assert record["assets"]["linux-amd64"]["sha256"] == "a" * 64
        assert record["assets"]["linux-arm64"]["sha256"] == "b" * 64
        assert record["assets"]["darwin-arm64"]["sha256"] == "c" * 64
        assert record["image"] == {
            "source": "docker.io/acme/mailpit:0.99.0",
            "index_digest": self.index_digest,
            "platforms": self.platform_digests,
        }
        expected = hashlib.sha256(output.read_bytes()).hexdigest()
        assert (output.with_name(output.name + ".sha256")).read_text() == expected + "\n"

    def test_source_tag_peels_and_preserves_distinct_hashes(self):
        result, output = self.run(self.descriptor("source-tag"))
        assert result.returncode == 0, result.stderr
        source = json.loads(output.read_text(encoding="utf-8"))["versions"][self.version]["source"]
        assert source["commit"] == self.commit
        assert source["url"].endswith("/archive/" + self.commit + ".tar.gz")
        assert source["sha256"] == self.archive_sha256
        assert source["fetch_from_github_hash"].startswith("sha256-")
        assert source["sha256"] != source["fetch_from_github_hash"]

    def test_lock_hook_fields_are_validated(self):
        hook = self.root / "lock.sh"
        hook_input = self.root / "hook-input.json"
        hook.write_text("#!/bin/sh\ncat > \"$LOCK_INPUT\"\nprintf '%s' '{\"vendorHash\":\"sha256-AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\"}'\n", encoding="utf-8")
        hook.chmod(0o755)
        result, output = self.run(self.descriptor("source-tag"), hook=hook, env={"LOCK_INPUT": str(hook_input)})
        assert result.returncode == 0, result.stderr
        source = json.loads(output.read_text(encoding="utf-8"))["versions"][self.version]["source"]
        assert source["vendorHash"].startswith("sha256-")
        hook_request = json.loads(hook_input.read_text(encoding="utf-8"))
        expected_hook_input = (
            json.dumps(
                {
                    "commit": self.commit,
                    "fetch_from_github_hash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                    "sha256": self.archive_sha256,
                    "url": "https://github.com/acme/mailpit/archive/" + self.commit + ".tar.gz",
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode()
        assert hook_input.read_bytes() == expected_hook_input
        assert hook_request["commit"] == self.commit
        assert hook_request["url"].endswith("/archive/" + self.commit + ".tar.gz")
        assert hook_request["sha256"] == self.archive_sha256
        assert hook_request["fetch_from_github_hash"].startswith("sha256-")

    def test_rejects_unstable_release(self):
        result, _ = self.run_with_fake_mutation(
            "gh", '"prerelease": False', '"prerelease": True'
        )
        assert result.returncode != 0
        assert "stable" in result.stderr.lower()

    def test_rejects_draft_release(self):
        result, _ = self.run_with_fake_mutation("gh", '"draft": False', '"draft": True')
        assert result.returncode != 0

    def test_rejects_missing_duplicate_or_non_uploaded_asset(self):
        missing = [asset for asset in self.default_assets if asset["name"] != "mailpit-linux-arm64.tar.gz"]
        result, _ = self.run_with_assets(missing)
        assert result.returncode != 0
        duplicate = self.default_assets + [dict(self.default_assets[0])]
        result, _ = self.run_with_assets(duplicate)
        assert result.returncode != 0
        not_uploaded = [dict(asset) for asset in self.default_assets]
        not_uploaded[0]["state"] = "new"
        result, _ = self.run_with_assets(not_uploaded)
        assert result.returncode != 0

    def test_rejects_absent_or_malformed_asset_digest(self):
        absent = [dict(asset) for asset in self.default_assets]
        absent[0]["digest"] = None
        result, _ = self.run_with_assets(absent)
        assert result.returncode != 0
        malformed = [dict(asset) for asset in self.default_assets]
        malformed[0]["digest"] = "bad"
        result, _ = self.run_with_assets(malformed)
        assert result.returncode != 0

    def test_rejects_missing_required_platform(self):
        descriptor = self.descriptor()
        descriptor["oci"]["required_platforms"] = ["linux/amd64"]
        result, _ = self.run(descriptor)
        assert result.returncode != 0

    def test_rejects_malformed_or_incomplete_oci_index(self):
        result, _ = self.run_with_oci(schema_version=1)
        assert result.returncode != 0
        result, _ = self.run_with_oci(index_media_type="application/octet-stream")
        assert result.returncode != 0
        result, _ = self.run_with_oci(child_media_type="application/octet-stream")
        assert result.returncode != 0

    def test_accepts_docker_manifest_list(self):
        descriptor = self.descriptor(
            "source-tag",
            repository="acme/vector",
            release_tag_template="v{version}",
            oci_repository="docker.io/timberio/vector",
            oci_tag_template="{version}-alpine",
        )
        result, _ = self.run_shape(
            "0.53.0",
            descriptor,
            "v0.53.0",
            "acme/vector",
            "docker.io/timberio/vector:0.53.0-alpine",
            index_media_type="application/vnd.docker.distribution.manifest.list.v2+json",
            child_media_type="application/vnd.docker.distribution.manifest.v2+json",
        )
        assert result.returncode == 0, result.stderr

    def test_rejects_bad_template_expansion(self):
        descriptor = self.descriptor()
        descriptor["github"]["release_tag_template"] = "v{other}"
        result, _ = self.run(descriptor)
        assert result.returncode != 0

    def test_accepts_registry_validated_non_semver_version_and_exact_tags(self):
        descriptor = self.descriptor(
            "source-tag",
            repository="acme/vector",
            release_tag_template="release-{version}",
            oci_repository="docker.io/timberio/vector",
            oci_tag_template="build-{version}",
        )
        result, output = self.run_shape(
            "2026.08",
            descriptor,
            "release-2026.08",
            "acme/vector",
            "docker.io/timberio/vector:build-2026.08",
        )
        assert result.returncode == 0, result.stderr
        record = json.loads(output.read_text(encoding="utf-8"))["versions"]["2026.08"]
        assert record["release_tag"] == "release-2026.08"
        assert record["image"]["source"] == "docker.io/timberio/vector:build-2026.08"

    def test_resolves_mailpit_release_assets_with_leading_v(self):
        version = "v1.31.0"
        repository = "acme/mailpit"
        release_tag = "v1.31.0"
        names = [
            "mailpit-darwin-arm64.tar.gz",
            "mailpit-linux-amd64.tar.gz",
            "mailpit-linux-arm64.tar.gz",
        ]
        descriptor = self.descriptor(
            "release-assets",
            repository=repository,
            release_tag_template="{version}",
            oci_repository="docker.io/acme/mailpit",
            oci_tag_template="{version}",
            asset_templates={target: name for target, name in zip(
                ("darwin-arm64", "linux-amd64", "linux-arm64"), names
            )},
        )
        result, output = self.run_release_shape(
            version,
            descriptor,
            release_tag,
            repository,
            "docker.io/acme/mailpit:v1.31.0",
            self.assets(repository, release_tag, names, ("d" * 64, "e" * 64, "f" * 64)),
        )
        assert result.returncode == 0, result.stderr
        record = json.loads(output.read_text(encoding="utf-8"))["versions"][version]
        assert record["release_tag"] == release_tag
        assert record["image"]["source"] == "docker.io/acme/mailpit:v1.31.0"
        for target, name, digest in zip(
            ("darwin-arm64", "linux-amd64", "linux-arm64"), names, ("d" * 64, "e" * 64, "f" * 64)
        ):
            assert record["assets"][target] == {
                "name": name,
                "url": f"https://github.com/{repository}/releases/download/{release_tag}/{name}",
                "sha256": digest,
            }

    def test_resolves_vector_release_assets_with_version_templates(self):
        version = "0.54.0"
        repository = "acme/vector"
        release_tag = "v0.54.0"
        names = [
            "vector-0.54.0-arm64-apple-darwin.tar.gz",
            "vector-0.54.0-x86_64-unknown-linux-musl.tar.gz",
            "vector-0.54.0-aarch64-unknown-linux-musl.tar.gz",
        ]
        targets = ("darwin-arm64", "linux-amd64", "linux-arm64")
        descriptor = self.descriptor(
            "release-assets",
            repository=repository,
            release_tag_template="v{version}",
            oci_repository="docker.io/timberio/vector",
            oci_tag_template="{version}-alpine",
            asset_templates={
                "darwin-arm64": "vector-{version}-arm64-apple-darwin.tar.gz",
                "linux-amd64": "vector-{version}-x86_64-unknown-linux-musl.tar.gz",
                "linux-arm64": "vector-{version}-aarch64-unknown-linux-musl.tar.gz",
            },
        )
        result, output = self.run_release_shape(
            version,
            descriptor,
            release_tag,
            repository,
            "docker.io/timberio/vector:0.54.0-alpine",
            self.assets(repository, release_tag, names, ("1" * 64, "2" * 64, "3" * 64)),
        )
        assert result.returncode == 0, result.stderr
        record = json.loads(output.read_text(encoding="utf-8"))["versions"][version]
        assert record["release_tag"] == release_tag
        assert record["image"]["source"] == "docker.io/timberio/vector:0.54.0-alpine"
        for target, name, digest in zip(targets, names, ("1" * 64, "2" * 64, "3" * 64)):
            assert record["assets"][target]["name"] == name
            assert record["assets"][target]["url"] == (
                f"https://github.com/{repository}/releases/download/{release_tag}/{name}"
            )
            assert record["assets"][target]["sha256"] == digest

    def test_resolves_imgproxy_source_hook_shape(self):
        descriptor = self.descriptor(
            "source-tag",
            repository="acme/imgproxy",
            release_tag_template="{version}",
            oci_repository="docker.io/imgproxy/imgproxy",
            oci_tag_template="{version}",
        )
        hook = self.root / "imgproxy-lock.sh"
        hook_input = self.root / "imgproxy-hook-input.json"
        hook.write_text(
            "#!/bin/sh\ncat > \"$LOCK_INPUT\"\nprintf '%s' '{\"vendorHash\":\"sha256-AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\"}'\n",
            encoding="utf-8",
        )
        hook.chmod(0o755)
        result, output = self.run_shape(
            "v3.30.0",
            descriptor,
            "v3.30.0",
            "acme/imgproxy",
            "docker.io/imgproxy/imgproxy:v3.30.0",
            hook=hook,
            LOCK_INPUT=str(hook_input),
        )
        assert result.returncode == 0, result.stderr
        source = json.loads(output.read_text(encoding="utf-8"))["versions"]["v3.30.0"]["source"]
        assert source["vendorHash"] == "sha256-AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
        expected_hook_input = (
            json.dumps(
                {
                    "commit": self.commit,
                    "fetch_from_github_hash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                    "sha256": self.archive_sha256,
                    "url": "https://github.com/acme/imgproxy/archive/" + self.commit + ".tar.gz",
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode()
        assert hook_input.read_bytes() == expected_hook_input

    def test_rejects_version_pattern_and_root_artifact(self):
        descriptor = self.descriptor()
        descriptor["version_pattern"] = r"^0\.[0-9]+\.[0-9]+$"
        result, _ = self.run(descriptor)
        assert result.returncode != 0

    def test_rejects_artifact_aliases_and_conflicting_union_fields(self):
        invalid_descriptors = []
        descriptor = self.descriptor("source-tag")
        descriptor["github"]["artifact"] = "source-tag"
        invalid_descriptors.append(descriptor)
        descriptor = self.descriptor("source-tag")
        descriptor["github"]["artifact"] = {"kind": "source-tag"}
        invalid_descriptors.append(descriptor)
        descriptor = self.descriptor("source-tag")
        descriptor["github"]["artifact"] = {"type": "source-tag", "kind": "release-assets"}
        invalid_descriptors.append(descriptor)
        descriptor = self.descriptor("release-assets")
        descriptor["github"]["artifact"]["asset_templates"] = descriptor["github"]["artifact"].pop("targets")
        invalid_descriptors.append(descriptor)
        descriptor = self.descriptor("release-assets")
        descriptor["github"]["artifact"]["targets"]["linux-amd64"] = {
            "template": "mailpit-linux-amd64.tar.gz"
        }
        invalid_descriptors.append(descriptor)
        for invalid in invalid_descriptors:
            result, _ = self.run(invalid)
            assert result.returncode != 0
        descriptor = self.descriptor()
        descriptor["artifact"] = descriptor["github"].pop("artifact")
        result, _ = self.run(descriptor)
        assert result.returncode != 0

    def test_rejects_malformed_hook_output(self):
        hook = self.root / "bad-lock.sh"
        hook.write_text("#!/bin/sh\nprintf '%s' '[]'\n", encoding="utf-8")
        hook.chmod(0o755)
        result, _ = self.run(self.descriptor("source-tag"), hook=hook)
        assert result.returncode != 0

    def test_rejects_tag_cycles_and_non_commit_targets(self):
        result, _ = self.run(
            self.descriptor("source-tag"),
            env={"FAKE_TAG_TYPE": "tag", "FAKE_TAG_SHA": "b" * 40},
        )
        assert result.returncode != 0
        result, _ = self.run(
            self.descriptor("source-tag"),
            env={"FAKE_TAG_TYPE": "blob", "FAKE_TAG_SHA": "b" * 40},
        )
        assert result.returncode != 0

    def test_rejects_malformed_lock_hash(self):
        hook = self.root / "bad-hash-lock.sh"
        hook.write_text("#!/bin/sh\nprintf '%s' '{\"vendorHash\":\"not-a-hash\"}'\n", encoding="utf-8")
        hook.chmod(0o755)
        result, _ = self.run(self.descriptor("source-tag"), hook=hook)
        assert result.returncode != 0

    def test_rejects_noncanonical_short_sri(self):
        hook = self.root / "short-hash-lock.sh"
        hook.write_text("#!/bin/sh\nprintf '%s' '{\"vendorHash\":\"sha256-A=\"}'\n", encoding="utf-8")
        hook.chmod(0o755)
        result, _ = self.run(self.descriptor("source-tag"), hook=hook)
        assert result.returncode != 0

    def test_resolver_is_deterministic(self):
        first, output = self.run()
        assert first.returncode == 0, first.stderr
        first_bytes = output.read_bytes()
        first_sidecar = output.with_name(output.name + ".sha256").read_bytes()
        second, output = self.run()
        assert second.returncode == 0, second.stderr
        assert output.read_bytes() == first_bytes
        assert output.with_name(output.name + ".sha256").read_bytes() == first_sidecar

    def test_publication_failure_never_exposes_partial_snapshot(self):
        import importlib.util

        spec = importlib.util.spec_from_file_location("external_release", ROOT_DIR / "scripts" / "external-release.py")
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        output = self.root / "published.json"
        sidecar = output.with_name(output.name + ".sha256")
        output.write_bytes(b"old-complete\n")
        sidecar.write_text("old-digest\n", encoding="utf-8")
        original_replace = module.os.replace
        calls = []

        def fail_second(source, destination):
            calls.append((source, destination))
            if len(calls) == 2:
                raise OSError("injected publication failure")
            return original_replace(source, destination)

        module.os.replace = fail_second
        try:
            try:
                module.write_snapshot({"repository": "acme/mailpit", "versions": {"v1.0.0": {}}}, output)
            except OSError:
                pass
            else:
                raise AssertionError("injected publication failure was ignored")
        finally:
            module.os.replace = original_replace
        assert output.read_bytes() == b'{"repository":"acme/mailpit","versions":{"v1.0.0":{}}}\n' or output.read_bytes() == b"old-complete\n"
        assert sidecar.read_text(encoding="utf-8") == "old-digest\n"


def main():
    test = ExternalReleaseIntegrationTest()
    try:
        methods = [name for name in dir(test) if name.startswith("test_")]
        for name in methods:
            getattr(test, name)()
    finally:
        test.close()


if __name__ == "__main__":
    main()
PY

echo "external release integration tests passed"
