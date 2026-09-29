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
import tempfile
import unittest


ROOT = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []


class ImageArtifactArchiveTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-image-artifact-archive."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.repo = self.temp / "repo"
        self.repo.mkdir()
        (self.repo / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            (self.repo / name).symlink_to(ROOT / name)
        (self.repo / "flake.nix").write_text("{}\n", encoding="utf-8")
        service = self.repo / "services/postgrest"
        service.mkdir(parents=True)
        (service / "recipe.env").write_text(
            'ARTIFACT_BACKEND="image"\nSOURCE_IMAGE="fixture/postgrest:latest"\n'
            'BASE_IMAGE="scratch"\nENTRYPOINT_JSON=\'[]\'\n'
            'CMD_JSON=\'["/bin/postgrest"]\'\n'
            'INCLUDE_PATHS=("/bin/postgrest")\nAUTO_ELF_DEPS="false"\nPORTABLE="true"\n',
            encoding="utf-8",
        )
        fake_bin = self.temp / "bin"
        fake_bin.mkdir()
        self.docker_log = self.temp / "docker.log"
        payload = self.temp / "postgrest"
        payload.write_text("fixture\n", encoding="utf-8")
        docker = fake_bin / "docker"
        docker.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            'printf "%s\n" "$*" >> "$DOCKER_LOG"\n'
            'case "$1" in\n'
            '  create) printf fixture-container ;;\n'
            '  cp) mkdir -p "$3"; cp "$DOCKER_PAYLOAD" "$3/postgrest" ;;\n'
            '  rm) ;;\n'
            '  *) exit 99 ;;\n'
            'esac\n',
            encoding="utf-8",
        )
        docker.chmod(0o755)
        nix = fake_bin / "nix"
        nix.write_text(
            "#!" + os.sys.executable + "\n"
            "import os\n"
            "path = os.environ['FAKE_NIX_OUTPUT']\n"
            "open(path, 'wb').write(b'fixture archive\\n')\n"
            "print(path)\n",
            encoding="utf-8",
        )
        nix.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            PATH=f"{fake_bin}:{self.env['PATH']}",
            FAKE_NIX_OUTPUT=str(self.temp / "fake-nix-output.tar.zst"),
            DOCKER_LOG=str(self.docker_log),
            DOCKER_PAYLOAD=str(payload),
            TARGET_OS="linux",
            ARCH="amd64",
            VERSION="1.2.3",
            ARTIFACT_ARCHIVE_ON_BUILD="0",
        )

    def run_cmd(self, command, env=None):
        merged = self.env.copy()
        merged.update(env or {})
        return subprocess.run(command, cwd=self.repo, env=merged, text=True, capture_output=True)

    def test_image_builder_can_defer_archive_and_stage_uses_manifest_archive(self):
        result = self.run_cmd([str(self.repo / "scripts/build-artifact.sh"), "postgrest", "1.2.3"])
        self.assertEqual(result.returncode, 0, result.stderr)
        artifact = self.repo / "artifacts/postgrest/1.2.3/linux-amd64"
        manifest = json.loads((artifact / "manifest.json").read_text())
        self.assertEqual(manifest["version"], "1.2.3-r0")
        self.assertEqual(manifest["upstream_version"], "1.2.3")
        self.assertEqual(manifest["revision"], 0)
        self.assertEqual(manifest["sbom"], "postgrest-1.2.3-r0-linux-amd64.sbom.spdx.json")
        self.assertIsNone(manifest["archive"])
        self.assertIsNone(manifest["size"]["archive_bytes"])
        self.assertFalse(any(artifact.glob("postgrest.tar*")))
        self.assertIn("fixture-container:/bin/postgrest", self.docker_log.read_text())

        archive_prefix = artifact / "postgrest-1.2.3-r0-linux-amd64"
        result = self.run_cmd([str(self.repo / "scripts/archive-artifact.sh"), str(artifact / "rootfs"), str(archive_prefix)])
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((artifact / "manifest.json").read_text())
        self.assertTrue((artifact / manifest["archive"]).is_file())
        (artifact / "postgrest.tar.zst").write_text("stale\n", encoding="utf-8")
        (artifact / "SHA256SUMS").write_text("fixture\n", encoding="utf-8")

        ruby = (
            'require "yaml"; w=YAML.safe_load(File.read(ARGV[0]), aliases: true); '
            's=w.fetch("jobs").values.flat_map{|j| j.fetch("steps",[])}.find{|x| x["name"]=="Stage release assets"}; '
            'abort "stage missing" unless s; puts s.fetch("run")'
        )
        stage = self.temp / "stage.sh"
        extracted = subprocess.run(
            ["ruby", "-e", ruby, str(ROOT / ".github/workflows/service-release.yml")],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(extracted.returncode, 0, extracted.stderr)
        stage.write_text("#!/usr/bin/env bash\n" + extracted.stdout, encoding="utf-8")
        stage.chmod(0o755)
        result = self.run_cmd(
            [str(stage)],
            {
                "SERVICE": "postgrest",
                "VERSION": "1.2.3",
                "RELEASE_VERSION": "1.2.3-r0",
                "PLATFORM_DIR": "linux-amd64",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        release = self.repo / "release-assets"
        self.assertTrue((release / manifest["archive"]).is_file())
        self.assertFalse((release / "postgrest.tar.zst").is_file())

    def test_stage_release_assets_hashes_manifest_without_gnu_sha256sum(self):
        result = self.run_cmd([str(self.repo / "scripts/build-artifact.sh"), "postgrest", "1.2.3"])
        self.assertEqual(result.returncode, 0, result.stderr)
        artifact = self.repo / "artifacts/postgrest/1.2.3/linux-amd64"

        archive_prefix = artifact / "postgrest-1.2.3-r0-linux-amd64"
        result = self.run_cmd([str(self.repo / "scripts/archive-artifact.sh"), str(artifact / "rootfs"), str(archive_prefix)])
        self.assertEqual(result.returncode, 0, result.stderr)
        before_entry = ("0" * 64, "aaa-before-entry")
        after_entry = ("f" * 64, "zzz-after-entry")
        (artifact / "SHA256SUMS").write_text(
            f"{before_entry[0]}  {before_entry[1]}\n{after_entry[0]}  {after_entry[1]}\n",
            encoding="utf-8",
        )

        ruby = (
            'require "yaml"; w=YAML.safe_load(File.read(ARGV[0]), aliases: true); '
            's=w.fetch("jobs").values.flat_map{|j| j.fetch("steps",[])}.find{|x| x["name"]=="Stage release assets"}; '
            'abort "stage missing" unless s; puts s.fetch("run")'
        )
        stage = self.temp / "stage.sh"
        extracted = subprocess.run(
            ["ruby", "-e", ruby, str(ROOT / ".github/workflows/service-release.yml")],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(extracted.returncode, 0, extracted.stderr)
        stage.write_text("#!/usr/bin/env bash\n" + extracted.stdout, encoding="utf-8")
        stage.chmod(0o755)

        # Simulate a macOS runner, which has no sha256sum: put a stub that
        # fails like the real absence (exit 127) first on PATH.
        no_coreutils_bin = self.temp / "no-sha256sum-bin"
        no_coreutils_bin.mkdir()
        fake_sha256sum = no_coreutils_bin / "sha256sum"
        fake_sha256sum.write_text(
            "#!/usr/bin/env bash\necho 'sha256sum: command not found' >&2\nexit 127\n",
            encoding="utf-8",
        )
        fake_sha256sum.chmod(0o755)
        restricted_path = f"{no_coreutils_bin}:{self.env['PATH']}"

        result = self.run_cmd(
            [str(stage)],
            {
                "SERVICE": "postgrest",
                "VERSION": "1.2.3",
                "RELEASE_VERSION": "1.2.3-r0",
                "PLATFORM_DIR": "linux-amd64",
                "PATH": restricted_path,
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        manifest_name = "postgrest-1.2.3-r0-linux-amd64.manifest.json"
        release_dir = self.repo / "release-assets"
        checksums = (release_dir / "postgrest-1.2.3-r0-linux-amd64.SHA256SUMS").read_text(
            encoding="utf-8"
        )
        lines = checksums.splitlines()
        manifest_lines = [line for line in lines if line.endswith(manifest_name)]
        self.assertEqual(len(manifest_lines), 1, checksums)
        manifest_line = manifest_lines[0]
        digest, sep, name = manifest_line.partition("  ")
        self.assertEqual(sep, "  ", manifest_line)
        self.assertRegex(digest, r"^[0-9a-f]{64}$", manifest_line)
        self.assertEqual(name, manifest_name)

        expected_digest = hashlib.sha256(
            (release_dir / manifest_name).read_bytes()
        ).hexdigest()
        self.assertEqual(digest, expected_digest, checksums)

        names = [line.partition("  ")[2] for line in lines]
        self.assertEqual(names, sorted(names), checksums)
        self.assertIn(f"{before_entry[0]}  {before_entry[1]}", lines, checksums)
        self.assertIn(f"{after_entry[0]}  {after_entry[1]}", lines, checksums)

    def test_revision_names_manifest_and_sbom(self):
        result = self.run_cmd(
            [str(self.repo / "scripts/build-artifact.sh"), "postgrest", "1.2.3"],
            {"REVISION": "2"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        artifact = self.repo / "artifacts/postgrest/1.2.3/linux-amd64"
        manifest = json.loads((artifact / "manifest.json").read_text())
        self.assertEqual(manifest["version"], "1.2.3-r2")
        self.assertEqual(manifest["upstream_version"], "1.2.3")
        self.assertEqual(manifest["revision"], 2)
        self.assertEqual(manifest["sbom"], "postgrest-1.2.3-r2-linux-amd64.sbom.spdx.json")

    def test_invalid_revision_is_rejected(self):
        result = self.run_cmd(
            [str(self.repo / "scripts/build-artifact.sh"), "postgrest", "1.2.3"],
            {"REVISION": "01"},
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("REVISION must be a non-negative integer", result.stderr)


if __name__ == "__main__":
    unittest.main()
PY

echo "image artifact archive tests passed"
