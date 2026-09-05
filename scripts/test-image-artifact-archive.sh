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
        self.assertIsNone(manifest["archive"])
        self.assertIsNone(manifest["size"]["archive_bytes"])
        self.assertFalse(any(artifact.glob("postgrest.tar*")))
        self.assertIn("fixture-container:/bin/postgrest", self.docker_log.read_text())

        archive_prefix = artifact / "postgrest-1.2.3-linux-amd64"
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
        result = self.run_cmd([str(stage)], {"SERVICE": "postgrest", "VERSION": "1.2.3", "PLATFORM_DIR": "linux-amd64"})
        self.assertEqual(result.returncode, 0, result.stderr)
        release = self.repo / "release-assets"
        self.assertTrue((release / manifest["archive"]).is_file())
        self.assertFalse((release / "postgrest.tar.zst").is_file())


if __name__ == "__main__":
    unittest.main()
PY

echo "image artifact archive tests passed"
