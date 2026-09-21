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

ROOT = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []
SEED = ROOT / "services" / "analytics" / "nix" / "seed-ezstd-zstd.sh"


class SeedEzstdZstdTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-ezstd-zstd."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.deps = self.temp / "deps"
        self.ezstd = self.deps / "ezstd"
        self.ezstd.mkdir(parents=True)
        (self.ezstd / "build_deps.sh").write_text("#!/bin/sh\nexit 42\n", encoding="utf-8")
        (self.ezstd / "build_deps.sh").chmod(0o644)
        self.zstd_lib = self.temp / "zstd-lib"
        self.zstd_dev = self.temp / "zstd-dev"
        (self.zstd_lib / "lib").mkdir(parents=True)
        (self.zstd_dev / "include").mkdir(parents=True)
        (self.zstd_lib / "lib" / "libzstd.a").write_text("static-lib", encoding="utf-8")
        (self.zstd_dev / "include" / "zstd.h").write_text("/* zstd */\n", encoding="utf-8")
        (self.zstd_dev / "include" / "zstd_errors.h").write_text("/* errors */\n", encoding="utf-8")

    def run_seed(self, *args):
        return subprocess.run(
            ["bash", str(SEED), *map(str, args)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_restores_hook_mode_and_seeds_libzstd(self):
        result = self.run_seed(self.deps, self.zstd_lib, self.zstd_dev)
        self.assertEqual(result.returncode, 0, result.stderr)
        hook = self.ezstd / "build_deps.sh"
        self.assertTrue(os.access(hook, os.X_OK))
        seeded = self.ezstd / "_build/deps/zstd/lib"
        self.assertEqual((seeded / "libzstd.a").read_text(encoding="utf-8"), "static-lib")
        self.assertEqual((seeded / "zstd.h").read_text(encoding="utf-8"), "/* zstd */\n")
        self.assertEqual(
            (seeded / "zstd_errors.h").read_text(encoding="utf-8"), "/* errors */\n"
        )

    def test_skips_unlocked_ezstd(self):
        shutil.rmtree(self.ezstd)
        result = self.run_seed(self.deps, self.zstd_lib, self.zstd_dev)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mix deps copy is missing", result.stderr)

    def test_requires_static_library(self):
        (self.zstd_lib / "lib" / "libzstd.a").unlink()
        result = self.run_seed(self.deps, self.zstd_lib, self.zstd_dev)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no static library", result.stderr)


if __name__ == "__main__":
    unittest.main()
PY
