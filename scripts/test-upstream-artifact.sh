#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import hashlib
import io
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT_DIR = pathlib.Path(sys.argv[1])
sys.argv[1:] = []
BUILD = ROOT_DIR / "scripts" / "build-artifact.sh"
RECORD = ROOT_DIR / "scripts" / "record-archive-digest.py"

CONTENTS = {
    "mailpit": (b"mailpit fixture executable\n", 0o755),
    "LICENSE": (b"Mailpit license\n", 0o644),
    "README.md": (b"Mailpit readme\n", 0o644),
}


def write_archive(path: pathlib.Path) -> str:
    with tarfile.open(path, "w:gz") as archive:
        for name, (payload, mode) in CONTENTS.items():
            info = tarfile.TarInfo(name)
            info.mode = mode
            info.size = len(payload)
            archive.addfile(info, io.BytesIO(payload))
    return hashlib.sha256(path.read_bytes()).hexdigest()


class UpstreamArtifactTest(unittest.TestCase):
    def setUp(self):
        self.directory = pathlib.Path(tempfile.mkdtemp(prefix="slim-upstream-artifact-test."))
        self.addCleanup(shutil.rmtree, self.directory)
        self.archive = self.directory / "mailpit-linux-amd64.tar.gz"
        self.digest = write_archive(self.archive)
        self.policy = self.directory / "policy.json"
        self.write_policy(self.digest)
        self.curl_log = self.directory / "curl.log"
        shim_dir = self.directory / "bin"
        shim_dir.mkdir()
        shim = shim_dir / "curl"
        shim.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f"printf '%s\\n' \"$*\" >> {self.curl_log!s}\n"
            f"cp {self.archive!s} \"${{@: -1}}\"\n",
            encoding="utf-8",
        )
        shim.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            {
                "UPSTREAM_ASSETS_FILE": str(self.policy),
                "TARGET_OS": "linux",
                "ARCH": "amd64",
                "ARTIFACT_ARCHIVE_ON_BUILD": "1",
                "PATH": f"{shim_dir}:{self.env['PATH']}",
            }
        )
        self.artifact_dir = ROOT_DIR / "artifacts" / "mailpit" / "v1.30.2" / "linux-amd64"
        self.linux_arm64_artifact_dir = ROOT_DIR / "artifacts" / "mailpit" / "v1.30.2" / "linux-arm64"
        self.darwin_artifact_dir = ROOT_DIR / "artifacts" / "mailpit" / "v1.30.2" / "darwin-arm64"
        self.addCleanup(shutil.rmtree, self.artifact_dir, ignore_errors=True)
        self.addCleanup(shutil.rmtree, self.linux_arm64_artifact_dir, ignore_errors=True)
        self.addCleanup(shutil.rmtree, self.darwin_artifact_dir, ignore_errors=True)

    def write_policy(self, digest: str):
        assets = {}
        for target in ("darwin-arm64", "linux-amd64", "linux-arm64"):
            name = f"mailpit-{target}.tar.gz"
            assets[target] = {
                "name": name,
                "url": f"https://github.com/axllent/mailpit/releases/download/v1.30.2/{name}",
                "sha256": digest,
            }
        policy = {
            "repository": "axllent/mailpit",
            "versions": {
                "v1.30.2": {
                    "release_tag": "v1.30.2",
                    "assets": assets,
                    "image": {
                        "source": "docker.io/axllent/mailpit:v1.30.2",
                        "index_digest": "sha256:" + "d" * 64,
                        "platforms": {
                            "linux/amd64": "sha256:" + "e" * 64,
                            "linux/arm64": "sha256:" + "f" * 64,
                        },
                    },
                }
            },
        }
        self.policy.write_text(json.dumps(policy), encoding="utf-8")

    def run_build(self, **env_overrides):
        env = self.env.copy()
        env.update(env_overrides)
        return subprocess.run(
            [str(BUILD), "mailpit", "v1.30.2"],
            cwd=ROOT_DIR,
            env=env,
            text=True,
            capture_output=True,
        )

    def artifact_dir_for(self, target_os, arch):
        return ROOT_DIR / "artifacts" / "mailpit" / "v1.30.2" / f"{target_os}-{arch}"

    def manifest_for_target(self, target_os, arch, **env_overrides):
        result = self.run_build(TARGET_OS=target_os, ARCH=arch, **env_overrides)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest_path = self.artifact_dir_for(target_os, arch) / "manifest.json"
        return json.loads(manifest_path.read_text(encoding="utf-8"))

    def vector_recipe_libc(self, target_os, arch):
        env = os.environ.copy()
        env.update({"TARGET_OS": target_os, "ARCH": arch, "UPSTREAM_ASSETS_FILE": str(self.policy)})
        env.pop("ARTIFACT_LIBC", None)
        result = subprocess.run(
            [
                "bash",
                "-c",
                "set -euo pipefail; source scripts/lib.sh; load_recipe vector; printf '%s' "
                '"${ARTIFACT_LIBC-}"',
            ],
            cwd=ROOT_DIR,
            env=env,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_build_verifies_then_normalizes_archive_and_records_provenance(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)

        rootfs = self.artifact_dir / "rootfs"
        self.assertEqual((rootfs / "bin/mailpit").read_bytes(), CONTENTS["mailpit"][0])
        self.assertEqual(stat.S_IMODE((rootfs / "bin/mailpit").stat().st_mode), 0o755)
        self.assertEqual((rootfs / "share/licenses/mailpit/LICENSE").read_bytes(), CONTENTS["LICENSE"][0])
        self.assertEqual((rootfs / "share/doc/mailpit/README.md").read_bytes(), CONTENTS["README.md"][0])

        manifest = json.loads((self.artifact_dir / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["libc"], "glibc")
        self.assertEqual(manifest["artifact_source"], "upstream-release-archive")
        self.assertEqual(manifest["provenance"]["kind"], "repackaged-upstream-release")
        self.assertEqual(manifest["provenance"]["repository"], "axllent/mailpit")
        self.assertEqual(manifest["provenance"]["upstream_asset"]["sha256"], self.digest)
        self.assertEqual(manifest["provenance"]["installed_members"]["mailpit"]["destination"], "bin/mailpit")
        self.assertEqual(
            manifest["provenance"]["installed_members"]["mailpit"]["destination_sha256"],
            hashlib.sha256(CONTENTS["mailpit"][0]).hexdigest(),
        )
        self.assertTrue((self.artifact_dir / manifest["sbom"]).is_file())
        archive = self.artifact_dir / manifest["archive"]
        self.assertEqual(archive.suffixes[-2:], [".tar", ".zst"])
        sums = self.artifact_dir / "SHA256SUMS"
        self.assertTrue(sums.is_file())
        archive_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.assertIn(f"{archive_sha256}  {archive.name}\n", sums.read_text(encoding="utf-8"))
        self.assertEqual(manifest["archive_sha256"], archive_sha256)
        self.assertEqual(
            manifest["provenance"]["normalized_archive"],
            {"name": archive.name, "sha256": archive_sha256},
        )

    def test_linux_archive_libc_override_is_recorded(self):
        result = self.run_build(ARTIFACT_LIBC="musl")
        self.assertEqual(result.returncode, 0, result.stderr)

        manifest = json.loads((self.artifact_dir / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["libc"], "musl")

    def test_darwin_archive_libc_remains_null_with_inherited_override(self):
        result = self.run_build(TARGET_OS="darwin", ARCH="arm64", ARTIFACT_LIBC="musl")
        self.assertEqual(result.returncode, 0, result.stderr)

        manifest = json.loads((self.darwin_artifact_dir / "manifest.json").read_text(encoding="utf-8"))
        self.assertIsNone(manifest["libc"])

    def test_runtime_metadata_matches_target(self):
        expected = (
            ("linux", "amd64", "glibc", "glibc", {}),
            ("linux", "arm64", "glibc", "glibc", {}),
            ("darwin", "arm64", None, None, {"RUNTIME_REQUIRES": "glibc"}),
        )
        for target_os, arch, runtime_requires, libc, env_overrides in expected:
            with self.subTest(target=f"{target_os}-{arch}"):
                manifest = self.manifest_for_target(target_os, arch, **env_overrides)
                self.assertEqual(manifest["runtime_requires"], runtime_requires)
                self.assertEqual(manifest["libc"], libc)

    def test_vector_recipe_only_overrides_libc_for_linux(self):
        self.assertEqual(self.vector_recipe_libc("linux", "amd64"), "musl")
        self.assertEqual(self.vector_recipe_libc("darwin", "arm64"), "")

    def test_invalid_linux_archive_libc_override_is_rejected(self):
        result = self.run_build(ARTIFACT_LIBC="uclibc")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("ARTIFACT_LIBC must be glibc or musl", result.stderr)

    def test_wrong_digest_fails_before_extraction(self):
        self.write_policy("0" * 64)
        result = self.run_build()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("sha256 mismatch", result.stderr)
        self.assertFalse(self.artifact_dir.exists())


class ArchiveDigestTest(unittest.TestCase):
    def invoke(self, manifest, archive, sums):
        return subprocess.run(
            [sys.executable, str(RECORD), str(manifest), str(archive), str(sums)],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
        )

    def setUp(self):
        self.directory = pathlib.Path(tempfile.mkdtemp(prefix="slim-archive-digest-test."))
        self.addCleanup(shutil.rmtree, self.directory)
        self.archive = self.directory / "mailpit-linux-amd64.tar.zst"
        self.archive.write_bytes(b"normalized archive")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.manifest = self.directory / "manifest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "artifact_source": "upstream-release-archive",
                    "provenance": {"kind": "repackaged-upstream-release"},
                }
            ),
            encoding="utf-8",
        )
        self.sums = self.directory / "SHA256SUMS"

    def test_accepts_sidecar_and_updates_common_archive_digest(self):
        self.sums.write_text(f"{self.digest}  {self.archive.name}\n", encoding="utf-8")
        result = self.invoke(self.manifest, self.archive, self.sums)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.manifest.read_text(encoding="utf-8"))
        self.assertEqual(manifest["archive_sha256"], self.digest)
        self.assertEqual(manifest["provenance"]["normalized_archive"]["sha256"], self.digest)

    def assert_rejected(self, sidecar, message):
        self.sums.write_text(sidecar, encoding="utf-8")
        result = self.invoke(self.manifest, self.archive, self.sums)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)

    def test_rejects_mismatched_sidecar(self):
        self.assert_rejected(f"{'0' * 64}  {self.archive.name}\n", "digest mismatch")

    def test_rejects_missing_sidecar_entry(self):
        self.assert_rejected(f"{self.digest}  other.tar.zst\n", "missing")

    def test_rejects_duplicate_sidecar_entries(self):
        self.assert_rejected(
            f"{self.digest}  {self.archive.name}\n{self.digest}  {self.archive.name}\n",
            "duplicate",
        )


if __name__ == "__main__":
    unittest.main()
PY

echo "upstream artifact tests passed"
