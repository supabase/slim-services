#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import struct
import tempfile
import unittest


ROOT_DIR = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []
SCANNER = ROOT_DIR / "scripts" / "os-floor.sh"


def elf_machine(path):
    try:
        with path.open("rb") as stream:
            data = stream.read(20)
    except OSError:
        return None
    if len(data) < 20 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return None
    return struct.unpack_from("<H", data, 18)[0]


def elf_paths(paths, *, executable=False):
    result = []
    seen = set()
    for path in paths:
        path = pathlib.Path(path)
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        if executable and not path.stat().st_mode & 0o111:
            continue
        if elf_machine(path) is not None:
            result.append(path)
    return result


class OsFloorScannerTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-os-floor."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.rootfs = self.temp / "rootfs"
        (self.rootfs / "bin").mkdir(parents=True)
        (self.rootfs / "lib").mkdir()

        consumer_candidates = elf_paths(
            [
                pathlib.Path("/usr/bin/true"),
                pathlib.Path("/bin/true"),
                *pathlib.Path("/nix/store").glob("*/lib/*.so.*"),
            ]
        )
        loader_candidates = elf_paths(
            [
                *pathlib.Path("/lib").glob("ld-linux*.so*"),
                *pathlib.Path("/lib64").glob("ld-linux*.so*"),
                *pathlib.Path("/usr/lib").glob("ld-linux*.so*"),
                *pathlib.Path("/lib").glob("*-linux-gnu/ld-linux*.so*"),
                *pathlib.Path("/usr/lib").glob("*-linux-gnu/ld-linux*.so*"),
                pathlib.Path("/lib64/ld-linux-x86-64.so.2"),
                pathlib.Path("/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"),
                *pathlib.Path("/nix/store").glob("*/lib/ld-linux-*.so.*"),
            ],
            executable=True,
        )
        libc_candidates = elf_paths(
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

        # Select a pair from one runtime directory.  Independent first-match
        # selection can pair a 32-bit loader with a 64-bit libc on hosts that
        # expose both, making the fixture look unlike a real bundled runtime.
        runtime_pair = next(
            (
                (loader, libc, elf_machine(loader))
                for loader in loader_candidates
                for libc in libc_candidates
                if loader.resolve().parent == libc.resolve().parent
                and elf_machine(loader) == elf_machine(libc)
            ),
            None,
        )
        if runtime_pair is None:
            self.skipTest(
                "a same-machine bundled loader/libc pair is required; "
                f"loaders={[str(path) for path in loader_candidates]}, "
                f"libcs={[str(path) for path in libc_candidates]}"
            )
        loader, libc, machine = runtime_pair
        consumer = next(
            (path for path in consumer_candidates if elf_machine(path) == machine),
            None,
        )
        if consumer is None:
            self.skipTest(
                "a host ELF consumer matching the bundled runtime is required; "
                f"machine={machine}, consumers={[str(path) for path in consumer_candidates]}"
            )

        self.runtime_sources = {
            "consumer": str(consumer),
            "loader": str(loader),
            "libc": str(libc),
            "machine": machine,
        }

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
        diagnostics = f"report={report}, runtime_sources={self.runtime_sources}"
        self.assertTrue(report["bundled_glibc"], diagnostics)
        self.assertGreaterEqual(report["scanned"], 3)
        self.assertIsNone(report["floor"], diagnostics)
        self.assertIsNone(report["offender"], diagnostics)

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
