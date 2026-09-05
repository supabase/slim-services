#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []


class HostSourceArtifactTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-host-source-artifact."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.repo = self.temp / "repo"
        self.repo.mkdir()
        (self.repo / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            (self.repo / name).symlink_to(ROOT / name)
        service = self.repo / "services/auth"
        source = self.repo / "sources/auth"
        service.mkdir(parents=True)
        source.mkdir(parents=True)
        (service / "recipe.env").write_text(
            'SOURCE_DIR="sources/auth"\nSOURCE_REF="fixture"\n'
            'ARTIFACT_BACKEND="host-source"\nBASE_IMAGE="scratch"\n'
            'ENTRYPOINT_JSON=\'[]\'\nCMD_JSON=\'["auth"]\'\n'
            'UPSTREAM_IMAGE="fixture/auth:fixture"\nPORTABLE="true"\n',
            encoding="utf-8",
        )
        host = service / "build-host.sh"
        host.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            ': "${SERVICE:?}" "${VERSION:?}" "${TARGET_OS:?}" "${ARCH:?}"\n'
            'mkdir -p "$ROOTFS/bin" "$ROOTFS/share/doc"\n'
            'printf fixture > "$ROOTFS/bin/auth"\nchmod 0755 "$ROOTFS/bin/auth"\n'
            'printf docs > "$ROOTFS/README.md"\nprintf license > "$ROOTFS/LICENSE"\n'
            'printf "%s|%s|%s|%s|%s|%s|%s\n" "$SERVICE" "$VERSION" "$TARGET_OS" "$ARCH" "$SOURCE_DIR" "$ROOTFS" "$ROOT_DIR" > "$HOST_TRACE"\n',
            encoding="utf-8",
        )
        host.chmod(0o755)
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "config", "user.email", "fixture@example.test"], check=True)
        subprocess.run(["git", "-C", str(source), "config", "user.name", "Fixture"], check=True)
        (source / "source.txt").write_text("fixture\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(source), "add", "source.txt"], check=True)
        subprocess.run(["git", "-C", str(source), "commit", "-qm", "fixture"], check=True)
        subprocess.run(["git", "-C", str(source), "tag", "fixture"], check=True)
        fake_bin = self.temp / "bin"
        fake_bin.mkdir()
        (fake_bin / "docker").write_text(
            '#!/usr/bin/env bash\nprintf docker-invoked > "$DOCKER_TRACE"\nexit 99\n',
            encoding="utf-8",
        )
        (fake_bin / "docker").chmod(0o755)
        self.host_trace = self.temp / "host.trace"
        self.docker_trace = self.temp / "docker.trace"
        self.env = os.environ.copy()
        self.env.update(
            PATH=f"{fake_bin}:{self.env['PATH']}",
            HOST_TRACE=str(self.host_trace),
            DOCKER_TRACE=str(self.docker_trace),
            ARTIFACT_ARCHIVE_ON_BUILD="1",
            VERSION="fixture",
            BASE_IMAGE="scratch",
            ENTRYPOINT_JSON="[]",
            CMD_JSON='["auth"]',
            UPSTREAM_IMAGE="fixture/auth:fixture",
            PORTABLE="true",
        )
        self.env.pop("PLATFORM", None)

    def run_build(self, **overrides):
        env = self.env.copy()
        env.update(overrides)
        return subprocess.run(
            [str(self.repo / "scripts/build-artifact.sh"), "auth", "fixture"],
            cwd=self.repo,
            env=env,
            text=True,
            capture_output=True,
        )

    def test_linux_and_darwin_use_host_builder_and_publish_contract(self):
        for target, arch in (("linux", "amd64"), ("darwin", "arm64")):
            with self.subTest(target=target):
                self.host_trace.unlink(missing_ok=True)
                result = self.run_build(TARGET_OS=target, ARCH=arch)
                self.assertEqual(result.returncode, 0, result.stderr)
                artifact = self.repo / "artifacts/auth/fixture" / f"{target}-{arch}"
                rootfs = artifact / "rootfs"
                self.assertEqual((rootfs / "bin/auth").read_text(), "fixture")
                self.assertFalse((rootfs / "README.md").exists())
                self.assertTrue((rootfs / "share/licenses/LICENSE").is_file())
                manifest = json.loads((artifact / "manifest.json").read_text())
                self.assertEqual(manifest["build_mode"], "host-source")
                self.assertIsNone(manifest["artifact_dockerfile"])
                self.assertTrue((artifact / manifest["sbom"]).is_file())
                self.assertTrue((artifact / manifest["archive"]).is_file())
                self.assertTrue(self.host_trace.is_file())
                self.assertFalse(self.docker_trace.exists())

    def test_rejects_wrong_ref_and_dirty_checkout_before_host_or_docker(self):
        source = self.repo / "sources/auth"
        (source / "source.txt").write_text("wrong\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(source), "add", "source.txt"], check=True)
        subprocess.run(["git", "-C", str(source), "commit", "-qm", "wrong"], check=True)
        result = self.run_build(TARGET_OS="linux", ARCH="amd64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected fixture", result.stderr)
        self.assertFalse(self.host_trace.exists())
        subprocess.run(["git", "-C", str(source), "checkout", "-q", "fixture"], check=True)
        (source / "dirty.txt").write_text("dirty\n", encoding="utf-8")
        result = self.run_build(TARGET_OS="linux", ARCH="amd64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local modifications", result.stderr)
        self.assertFalse(self.host_trace.exists())

    def test_requires_explicit_backend(self):
        recipe = self.repo / "services/auth/recipe.env"
        recipe.write_text(recipe.read_text().replace('ARTIFACT_BACKEND="host-source"\n', ""))
        result = self.run_build(TARGET_OS="linux", ARCH="amd64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown ARTIFACT_BACKEND", result.stderr)
        self.assertFalse(self.host_trace.exists())
        self.assertFalse(self.docker_trace.exists())


if __name__ == "__main__":
    unittest.main()
PY

echo "host-source artifact tests passed"
