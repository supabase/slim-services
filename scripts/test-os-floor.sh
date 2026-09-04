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


ROOT_DIR = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []
SCANNER = ROOT_DIR / "scripts" / "os-floor.sh"


def is_elf(path):
    try:
        with path.open("rb") as stream:
            return stream.read(4) == b"\x7fELF"
    except OSError:
        return False


def first_elf(paths):
    for path in paths:
        path = pathlib.Path(path)
        if path.is_file() and is_elf(path):
            return path
    return None


class OsFloorScannerTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-os-floor."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.rootfs = self.temp / "rootfs"
        (self.rootfs / "bin").mkdir(parents=True)
        (self.rootfs / "lib").mkdir()

        consumer = first_elf(
            [
                pathlib.Path("/usr/bin/true"),
                pathlib.Path("/bin/true"),
                *pathlib.Path("/nix/store").glob("*/lib/*.so.*"),
            ]
        )
        loader = first_elf(
            [
                *pathlib.Path("/lib").glob("ld-linux*.so*"),
                *pathlib.Path("/lib64").glob("ld-linux*.so*"),
                *pathlib.Path("/usr/lib").glob("ld-linux*.so*"),
                *pathlib.Path("/lib").glob("*-linux-gnu/ld-linux*.so*"),
                *pathlib.Path("/usr/lib").glob("*-linux-gnu/ld-linux*.so*"),
                pathlib.Path("/lib64/ld-linux-x86-64.so.2"),
                pathlib.Path("/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"),
                *pathlib.Path("/nix/store").glob("*/lib/ld-linux-*.so.*"),
            ]
        )
        libc = first_elf(
            [
                *pathlib.Path("/lib").glob("libc.so.*"),
                *pathlib.Path("/lib64").glob("libc.so.*"),
                *pathlib.Path("/usr/lib").glob("libc.so.*"),
                *pathlib.Path("/lib").glob("*-linux-gnu/libc.so.*"),
                *pathlib.Path("/usr/lib").glob("*-linux-gnu/libc.so.*"),
                pathlib.Path("/lib/x86_64-linux-gnu/libc.so.6"),
                pathlib.Path("/lib64/libc.so.6"),
                *pathlib.Path("/nix/store").glob("*/lib/libc.so.6"),
            ]
        )
        if not (consumer and loader and libc):
            self.skipTest("a host Linux ELF consumer, loader, and libc are required")

        shutil.copy2(consumer, self.rootfs / "bin" / "consumer")
        shutil.copy2(loader, self.rootfs / "lib" / loader.name)
        shutil.copy2(libc, self.rootfs / "lib" / "libc.so.6")

    def test_bundled_glibc_does_not_define_host_os_floor(self):
        result = subprocess.run(
            [str(SCANNER), "--linux", str(self.rootfs)],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["kind"], "glibc")
        self.assertTrue(report["bundled_glibc"])
        self.assertGreaterEqual(report["scanned"], 3)
        self.assertIsNone(report["floor"])
        self.assertIsNone(report["offender"])

    def test_non_executable_loader_does_not_claim_bundled_glibc(self):
        loader = next((path for path in (self.rootfs / "lib").glob("ld-linux*")), None)
        self.assertIsNotNone(loader)
        loader.chmod(0o644)
        result = subprocess.run(
            [str(SCANNER), "--linux", str(self.rootfs)],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertFalse(report["bundled_glibc"])
        self.assertIsNotNone(report["floor"])
        self.assertEqual(report["offender"], "bin/consumer")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(OsFloorScannerTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
PY
