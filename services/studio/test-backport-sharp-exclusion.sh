#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT_DIR = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []
BACKPORT = ROOT_DIR / "services" / "studio" / "backport-sharp-exclusion.py"
FIXTURES = ROOT_DIR / "services" / "studio" / "fixtures" / "next-config"


class BackportSharpExclusionTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-studio-backport."))
        self.addCleanup(shutil.rmtree, self.temp)

    def run_backport(self, config_path):
        return subprocess.run(
            ["python3", str(BACKPORT), str(config_path)],
            text=True,
            capture_output=True,
            check=False,
        )

    def copy_fixture(self, name):
        source = FIXTURES / name
        destination = self.temp / name
        shutil.copy(source, destination)
        return destination

    def assert_patched(self, original: str, patched: str) -> None:
        self.assertIn(
            "unoptimized: process.env.NEXT_PUBLIC_IS_PLATFORM !== 'true',", patched
        )
        self.assertIn("outputFileTracingExcludes", patched)
        self.assertIn(
            "'*': ['../../**/node_modules/sharp/**/*', '../../**/node_modules/@img/**/*'],",
            patched,
        )
        # Every line of the original config must still be present, in order,
        # once the two inserted edits are accounted for: the backport must
        # not touch anything else in the file.
        original_lines = original.splitlines()
        patched_lines = patched.splitlines()
        cursor = 0
        for line in original_lines:
            try:
                cursor = patched_lines.index(line, cursor) + 1
            except ValueError:
                self.fail(f"original line missing from patched config: {line!r}")

    def test_2026_09_21_is_patched(self):
        config = self.copy_fixture("next.config.2026.09.21-sha-512201d.ts")
        original = config.read_text(encoding="utf-8")

        result = self.run_backport(config)

        self.assertEqual(result.returncode, 0, result.stderr)
        patched = config.read_text(encoding="utf-8")
        self.assertNotEqual(original, patched)
        self.assert_patched(original, patched)

    def test_2026_09_28_is_left_byte_identical(self):
        config = self.copy_fixture("next.config.2026.09.28-sha-5e59b60.ts")
        original = config.read_text(encoding="utf-8")

        result = self.run_backport(config)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config.read_text(encoding="utf-8"), original)

    def test_2026_09_14_is_patched(self):
        config = self.copy_fixture("next.config.2026.09.14-sha-4dd8a95.ts")
        original = config.read_text(encoding="utf-8")

        result = self.run_backport(config)

        self.assertEqual(result.returncode, 0, result.stderr)
        patched = config.read_text(encoding="utf-8")
        self.assertNotEqual(original, patched)
        self.assert_patched(original, patched)

    def test_config_missing_anchors_fails_loudly(self):
        config = self.copy_fixture("next.config.missing-anchors.ts")

        result = self.run_backport(config)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(config), result.stderr)
        self.assertIn("anchor", result.stderr)

    def test_missing_config_file_fails_loudly(self):
        missing = self.temp / "next.config.ts"

        result = self.run_backport(missing)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(missing), result.stderr)
        self.assertIn("not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
PY

echo "Studio sharp-exclusion backport tests passed"
