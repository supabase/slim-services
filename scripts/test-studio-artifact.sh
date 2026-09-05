#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT_DIR = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []
NORMALIZE = ROOT_DIR / "services" / "studio" / "normalize-next-standalone.sh"
VALIDATE = ROOT_DIR / "services" / "studio" / "validate-artifact.sh"


class StudioArtifactBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-studio-artifact."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.standalone = self.temp / "standalone"
        self.installed_store = self.temp / "installed/node_modules/.pnpm"
        self.rootfs = self.temp / "rootfs"
        self.manifest = self.temp / "manifest.json"
        self.standalone.mkdir()
        self.rootfs.mkdir()

    def write_required_runtime(self, root):
        for path in (
            "bin/studio",
            "node/bin/node",
            "app/apps/studio/docker-entrypoint.mjs",
            "app/apps/studio/server.js",
        ):
            destination = root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text("fixture", encoding="utf-8")
        (root / "bin/studio").chmod(0o755)
        (root / "node/bin/node").chmod(0o755)

    def write_manifest(self, manifest=None):
        (manifest or self.manifest).write_text(
            '{\n'
            '  "entrypoint": ["/slim-runtime/bin/studio"],\n'
            '  "cmd": ["/node/bin/node", "apps/studio/server.js"]\n'
            '}\n',
            encoding="utf-8",
        )

    def write_valid_pnpm_alias(self, root):
        stores = root / "app/node_modules/.pnpm"
        target = stores / "escape-string-regexp@5.0.0/node_modules/escape-string-regexp"
        target.mkdir(parents=True)
        aliases = stores / "node_modules"
        aliases.mkdir(parents=True)
        (aliases / "escape-string-regexp").symlink_to(
            "../escape-string-regexp@5.0.0/node_modules/escape-string-regexp"
        )

    def run_script(self, script, *args):
        return subprocess.run(
            ["bash", str(script), *map(str, args)],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            check=False,
        )

    def write_installed_pnpm_target(self, package, version):
        target = self.installed_store / f"{package}@{version}/node_modules/{package}"
        target.mkdir(parents=True)
        (target / "package.json").write_text(
            f'{{"name":"{package}","version":"{version}"}}\n',
            encoding="utf-8",
        )
        return target

    def test_next_standalone_materializes_exact_dangling_pnpm_aliases(self):
        stores = self.standalone / "app/node_modules/.pnpm"
        (stores / "escape-string-regexp@5.0.0/node_modules/escape-string-regexp").mkdir(
            parents=True
        )
        (stores / "node_modules").mkdir(parents=True)
        (stores / "node_modules/escape-string-regexp").symlink_to(
            "../escape-string-regexp@4.0.0/node_modules/escape-string-regexp"
        )
        (stores / "node_modules/semver").symlink_to(
            "../semver@6.3.1/node_modules/semver"
        )
        (stores / "node_modules/valid").symlink_to(
            "../escape-string-regexp@5.0.0/node_modules/escape-string-regexp"
        )
        escape_v4 = self.write_installed_pnpm_target("escape-string-regexp", "4.0.0")
        semver_v6 = self.write_installed_pnpm_target("semver", "6.3.1")

        result = self.run_script(NORMALIZE, self.standalone, self.installed_store)

        self.assertEqual(result.returncode, 0, result.stderr)
        escape_alias = stores / "node_modules/escape-string-regexp"
        semver_alias = stores / "node_modules/semver"
        valid_alias = stores / "node_modules/valid"
        valid_destination = stores / "escape-string-regexp@5.0.0/node_modules/escape-string-regexp"
        escape_v4_destination = stores / "escape-string-regexp@4.0.0/node_modules/escape-string-regexp"
        semver_v6_destination = stores / "semver@6.3.1/node_modules/semver"
        self.assertTrue(escape_alias.is_symlink())
        self.assertTrue(semver_alias.is_symlink())
        self.assertEqual(escape_alias.resolve(strict=True), escape_v4_destination.resolve())
        self.assertEqual(semver_alias.resolve(strict=True), semver_v6_destination.resolve())
        self.assertEqual(
            (escape_v4_destination / "package.json").read_text(encoding="utf-8"),
            (escape_v4 / "package.json").read_text(encoding="utf-8"),
        )
        self.assertEqual(
            (semver_v6_destination / "package.json").read_text(encoding="utf-8"),
            (semver_v6 / "package.json").read_text(encoding="utf-8"),
        )
        self.assertTrue((escape_alias.resolve(strict=True) / "package.json").is_file())
        self.assertTrue((semver_alias.resolve(strict=True) / "package.json").is_file())
        self.assertTrue(valid_alias.is_symlink())
        self.assertEqual(valid_alias.resolve(strict=True), valid_destination.resolve())

    def test_next_standalone_materialization_fails_when_exact_target_is_missing(self):
        stores = self.standalone / "app/node_modules/.pnpm"
        (stores / "node_modules").mkdir(parents=True)
        self.installed_store.mkdir(parents=True)
        (stores / "node_modules/escape-string-regexp").symlink_to(
            "../escape-string-regexp@4.0.0/node_modules/escape-string-regexp"
        )

        result = self.run_script(NORMALIZE, self.standalone, self.installed_store)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed pnpm target not found", result.stderr)

    def test_assembled_tree_requires_runtime_paths_and_resolved_entrypoint(self):
        self.write_required_runtime(self.rootfs)
        app = self.rootfs / "app/node_modules/.pnpm/node_modules"
        app.mkdir(parents=True)
        (app / "escape-string-regexp").symlink_to(
            "../escape-string-regexp@4.0.0/node_modules/escape-string-regexp"
        )

        result = self.run_script(VALIDATE, self.rootfs)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dangling symlink", result.stderr)

    def test_assembled_tree_rejects_symlink_outside_root(self):
        self.write_required_runtime(self.rootfs)
        (self.temp / "outside").write_text("outside", encoding="utf-8")
        (self.rootfs / "app/outside").symlink_to("../../outside")

        result = self.run_script(VALIDATE, self.rootfs)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside artifact root", result.stderr)

    def test_assembled_tree_accepts_required_runtime_layout(self):
        self.write_required_runtime(self.rootfs)
        self.write_valid_pnpm_alias(self.rootfs)
        self.write_manifest()
        archive = self.temp / "studio.tar"
        archived = subprocess.run(
            ["tar", "-cf", str(archive), "-C", str(self.rootfs), "."],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(archived.returncode, 0, archived.stderr)
        extracted = self.temp / "extracted"
        extracted.mkdir()
        extracted_result = subprocess.run(
            ["tar", "-xf", str(archive), "-C", str(extracted)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(extracted_result.returncode, 0, extracted_result.stderr)

        result = self.run_script(VALIDATE, extracted, self.manifest)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_assembled_tree_rejects_missing_published_entrypoint(self):
        self.write_required_runtime(self.rootfs)
        (self.rootfs / "app/apps/studio/docker-entrypoint.mjs").unlink()

        result = self.run_script(VALIDATE, self.rootfs)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "missing required runtime path: app/apps/studio/docker-entrypoint.mjs",
            result.stderr,
        )

    def test_assembled_tree_rejects_non_executable_runtime_binaries(self):
        self.write_required_runtime(self.rootfs)
        for relative_path in ("bin/studio", "node/bin/node"):
            with self.subTest(relative_path=relative_path):
                (self.rootfs / relative_path).chmod(0o644)
                result = self.run_script(VALIDATE, self.rootfs)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be executable", result.stderr)
                (self.rootfs / relative_path).chmod(0o755)

    def test_manifest_entrypoint_mismatch_is_rejected(self):
        self.write_required_runtime(self.rootfs)
        self.write_manifest()
        self.manifest.write_text(
            self.manifest.read_text(encoding="utf-8").replace(
                "/slim-runtime/bin/studio",
                "/slim-runtime/bin/missing",
            ),
            encoding="utf-8",
        )

        result = self.run_script(VALIDATE, self.rootfs, self.manifest)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest entrypoint mismatch", result.stderr)

    def test_manifest_entrypoint_extra_argument_is_rejected(self):
        self.write_required_runtime(self.rootfs)
        self.write_manifest()
        self.manifest.write_text(
            self.manifest.read_text(encoding="utf-8").replace(
                '"/slim-runtime/bin/studio"],',
                '"/slim-runtime/bin/studio", "--extra"],',
            ),
            encoding="utf-8",
        )

        result = self.run_script(VALIDATE, self.rootfs, self.manifest)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest entrypoint mismatch", result.stderr)

    def test_manifest_entrypoint_missing_target_is_rejected(self):
        self.write_required_runtime(self.rootfs)
        self.write_manifest()
        (self.rootfs / "bin/studio").unlink()

        result = self.run_script(VALIDATE, self.rootfs, self.manifest)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest entrypoint target missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
PY

echo "Studio artifact boundary tests passed"
