#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -I - "$ROOT_DIR" <<'PY'
import os
import pathlib
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT_DIR = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []
TOOL = ROOT_DIR / "scripts" / "lower-macho-minos.py"


def ver(major, minor=0, patch=0):
    return (major << 16) | (minor << 8) | patch


def macho(commands):
    """Build a minimal arm64 Mach-O whose load commands are COMMANDS."""
    body = b"".join(commands)
    header = struct.pack(
        "<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, len(commands), len(body), 0, 0
    )
    return header + body


def build_version(platform, minos, sdk):
    return struct.pack("<IIIIII", 0x32, 24, platform, minos, sdk, 0)


def version_min(minos, sdk):
    return struct.pack("<IIII", 0x24, 16, minos, sdk)


def segment():
    return struct.pack("<II", 0x19, 8)


def fat(slices):
    offset = 8 + 20 * len(slices)
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    entries, blobs = b"", b""
    for blob in slices:
        entries += struct.pack(">IIIII", 0x0100000C, 0, offset + len(blobs), len(blob), 0)
        blobs += blob
    return header + entries + blobs


class LowerMachoMinosTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-lower-minos."))
        self.addCleanup(shutil.rmtree, self.temp)

    def run_tool(self, target, data):
        path = self.temp / "bin"
        path.write_bytes(data)
        result = subprocess.run(
            ["python3", "-I", str(TOOL), target, str(path)],
            capture_output=True,
            text=True,
            check=True,
        )
        return path.read_bytes(), result.stdout

    def test_lowers_build_version_and_keeps_sdk_and_other_bytes(self):
        before = macho([segment(), build_version(1, ver(15), ver(15, 5))])
        after, out = self.run_tool("14.0", before)
        self.assertIn("lowered minos 15.0 -> 14.0", out)
        self.assertEqual(
            after, macho([segment(), build_version(1, ver(14), ver(15, 5))])
        )

    def test_already_within_target_is_byte_identical(self):
        before = macho([build_version(1, ver(14), ver(14, 5))])
        after, out = self.run_tool("14.0", before)
        self.assertEqual(after, before)
        self.assertIn("already <= 14.0", out)

    def test_never_raises_minos(self):
        before = macho([build_version(1, ver(11, 0), ver(14, 5))])
        after, _ = self.run_tool("14.0", before)
        self.assertEqual(after, before)

    def test_leaves_non_macos_platforms_alone(self):
        before = macho([build_version(2, ver(17), ver(17, 5))])  # iOS
        after, _ = self.run_tool("14.0", before)
        self.assertEqual(after, before)

    def test_lowers_legacy_version_min_macosx(self):
        after, _ = self.run_tool("14.0", macho([version_min(ver(15), ver(15, 5))]))
        self.assertEqual(after, macho([version_min(ver(14), ver(15, 5))]))

    def test_lowers_every_fat_slice(self):
        high = macho([build_version(1, ver(15, 2), ver(15, 5))])
        low = macho([build_version(1, ver(14), ver(15, 5))])
        after, _ = self.run_tool("14.0", fat([high, high]))
        self.assertEqual(after, fat([low, low]))

    def test_non_macho_is_ignored(self):
        after, out = self.run_tool("14.0", b"#!/bin/sh\necho hi\n")
        self.assertEqual(after, b"#!/bin/sh\necho hi\n")
        self.assertIn("already <= 14.0", out)

    def test_os_floor_scanner_agrees(self):
        if not shutil.which("otool"):
            self.skipTest("otool not available")
        rootfs = self.temp / "rootfs"
        (rootfs / "bin").mkdir(parents=True)
        (rootfs / "bin" / "postgrest").write_bytes(
            macho([build_version(1, ver(15), ver(15, 5))])
        )
        subprocess.run(
            ["python3", "-I", str(TOOL), "14.0", str(rootfs / "bin" / "postgrest")],
            check=True,
            capture_output=True,
        )
        out = subprocess.run(
            [str(ROOT_DIR / "scripts" / "os-floor.sh"), "--darwin", str(rootfs)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertIn('"floor": "14.0"', out)


unittest.main(verbosity=1)
PY
