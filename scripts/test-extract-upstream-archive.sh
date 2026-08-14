#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import hashlib
import io
import json
import pathlib
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT_DIR = pathlib.Path(sys.argv[1])
sys.argv[1:] = []
SCRIPT = ROOT_DIR / "scripts" / "extract-upstream-archive.py"
MAPPING = {
    "mailpit": "bin/mailpit",
    "LICENSE": "share/licenses/mailpit/LICENSE",
    "README.md": "share/doc/mailpit/README.md",
}
EXECUTABLES = ["mailpit"]
CONTENTS = {
    "mailpit": (b"mailpit executable bytes\x00\x01\n", 0o755),
    "LICENSE": (b"Mailpit license\n", 0o644),
    "README.md": (b"Mailpit readme\n", 0o644),
}
ROOT = "vector-x86_64-unknown-linux-gnu"
ROOTED_MAPPING = {
    "bin/vector": "bin/vector",
    "LICENSE": "share/licenses/vector/LICENSE",
    "config/default.toml": "share/vector/default.toml",
}
ROOTED_EXECUTABLES = ["bin/vector"]
MIXED_ROOT_MAPPING = {"bin/vector": "bin/vector"}
MIXED_ROOT_EXECUTABLES = ["bin/vector"]
ROOTED_CONTENTS = {
    "bin/vector": (b"vector executable bytes\x00\x01\n", 0o755),
    "LICENSE": (b"Vector license\n", 0o644),
    "config/default.toml": (b"[sources]\n", 0o644),
}


def add_member(archive, name, payload=None, mode=0o644, kind=tarfile.REGTYPE, linkname=""):
    info = tarfile.TarInfo(name)
    info.mode = mode
    info.type = kind
    info.linkname = linkname
    if payload is not None:
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
    else:
        archive.addfile(info)


def write_archive(path, entries):
    with tarfile.open(path, "w:gz") as archive:
        for entry in entries:
            add_member(archive, *entry)


def valid_entries():
    return [
        (name, payload, mode)
        for name, (payload, mode) in CONTENTS.items()
    ]


def rooted_entries():
    return [
        (ROOT, None, 0o755, tarfile.DIRTYPE, ""),
        (f"{ROOT}/bin", None, 0o755, tarfile.DIRTYPE, ""),
        (f"{ROOT}/config", None, 0o755, tarfile.DIRTYPE, ""),
        (f"{ROOT}/share", None, 0o755, tarfile.DIRTYPE, ""),
        (f"{ROOT}/share/licenses", None, 0o755, tarfile.DIRTYPE, ""),
        (f"{ROOT}/share/vector", None, 0o755, tarfile.DIRTYPE, ""),
        (f"{ROOT}/bin/vector", *ROOTED_CONTENTS["bin/vector"]),
        (f"{ROOT}/LICENSE", *ROOTED_CONTENTS["LICENSE"]),
        (f"{ROOT}/config/default.toml", *ROOTED_CONTENTS["config/default.toml"]),
    ]


def dot_rooted_entries():
    return [(f"./{entry[0]}", *entry[1:]) for entry in rooted_entries()]


class ExtractUpstreamArchiveTest(unittest.TestCase):
    def invoke(self, archive, rootfs, mapping=MAPPING, executables=EXECUTABLES):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(archive),
                str(rootfs),
                json.dumps(mapping, sort_keys=True),
                json.dumps(executables),
            ],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
        )

    def test_installs_expected_layout_modes_and_byte_identical_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            archive = directory / "mailpit.tar.gz"
            rootfs = directory / "rootfs"
            write_archive(archive, valid_entries())

            result = self.invoke(archive, rootfs)

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            expected_report = {
                "members": {
                    source: {
                        "destination": destination,
                        "source_sha256": hashlib.sha256(CONTENTS[source][0]).hexdigest(),
                        "destination_sha256": hashlib.sha256(CONTENTS[source][0]).hexdigest(),
                    }
                    for source, destination in MAPPING.items()
                }
            }
            self.assertEqual(report, expected_report)
            self.assertEqual(
                result.stdout,
                json.dumps(expected_report, indent=2, sort_keys=True) + "\n",
            )

            for source, destination in MAPPING.items():
                installed = rootfs / destination
                self.assertEqual(installed.read_bytes(), CONTENTS[source][0])
                self.assertEqual(stat.S_IMODE(installed.stat().st_mode), CONTENTS[source][1])

            source_digest = hashlib.sha256((rootfs / "bin/mailpit").read_bytes()).hexdigest()
            self.assertEqual(source_digest, hashlib.sha256(CONTENTS["mailpit"][0]).hexdigest())

    def test_installs_rooted_nested_archive_after_normalizing_root(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            archive = directory / "vector.tar.gz"
            rootfs = directory / "rootfs"
            write_archive(archive, rooted_entries())

            result = self.invoke(archive, rootfs, ROOTED_MAPPING, ROOTED_EXECUTABLES)

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            expected_report = {
                "members": {
                    source: {
                        "destination": destination,
                        "source_sha256": hashlib.sha256(ROOTED_CONTENTS[source][0]).hexdigest(),
                        "destination_sha256": hashlib.sha256(ROOTED_CONTENTS[source][0]).hexdigest(),
                    }
                    for source, destination in ROOTED_MAPPING.items()
                }
            }
            self.assertEqual(report, expected_report)
            for source, destination in ROOTED_MAPPING.items():
                installed = rootfs / destination
                self.assertEqual(installed.read_bytes(), ROOTED_CONTENTS[source][0])
                self.assertEqual(stat.S_IMODE(installed.stat().st_mode), ROOTED_CONTENTS[source][1])

    def test_installs_rooted_archive_with_conventional_dot_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            archive = directory / "vector-dot-prefix.tar.gz"
            rootfs = directory / "rootfs"
            write_archive(archive, dot_rooted_entries())

            result = self.invoke(archive, rootfs, ROOTED_MAPPING, ROOTED_EXECUTABLES)

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(set(report["members"]), set(ROOTED_MAPPING))
            for source, destination in ROOTED_MAPPING.items():
                installed = rootfs / destination
                self.assertEqual(installed.read_bytes(), ROOTED_CONTENTS[source][0])

    def assert_rejected(self, entries, label, diagnostic, mapping=MAPPING, executables=EXECUTABLES):
        with self.subTest(label=label):
            with tempfile.TemporaryDirectory() as directory:
                directory = pathlib.Path(directory)
                archive = directory / "invalid.tar.gz"
                rootfs = directory / "rootfs"
                write_archive(archive, entries)

                result = self.invoke(archive, rootfs, mapping, executables)

                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(diagnostic, result.stderr)
                self.assertFalse(rootfs.exists() and any(rootfs.rglob("*")))

    def test_rejects_unsafe_paths(self):
        for name in ("/mailpit", "../mailpit", "nested/mailpit"):
            entries = valid_entries()
            entries[0] = (name, *CONTENTS["mailpit"])
            self.assert_rejected(entries, name, "unsafe archive member path")

    def test_rejects_duplicate_members(self):
        entries = valid_entries() + [("mailpit", *CONTENTS["mailpit"])]
        self.assert_rejected(entries, "duplicate member", "duplicate archive member")

    def test_rejects_multiple_archive_roots(self):
        entries = rooted_entries() + [("other-root", None, 0o755, tarfile.DIRTYPE, "")]
        self.assert_rejected(
            entries,
            "multiple roots",
            "multiple archive roots",
            ROOTED_MAPPING,
            ROOTED_EXECUTABLES,
        )

    def test_rejects_duplicate_normalized_members(self):
        entries = rooted_entries() + [(f"{ROOT}/bin/vector/", None, 0o755, tarfile.DIRTYPE, "")]
        self.assert_rejected(
            entries,
            "duplicate normalized member",
            "duplicate archive member",
            ROOTED_MAPPING,
            ROOTED_EXECUTABLES,
        )

    def test_rejects_mixed_dot_prefix_duplicate_root(self):
        entries = [
            ("root", None, 0o755, tarfile.DIRTYPE, ""),
            ("./root", None, 0o755, tarfile.DIRTYPE, ""),
            ("root/bin", None, 0o755, tarfile.DIRTYPE, ""),
            ("root/bin/vector", *ROOTED_CONTENTS["bin/vector"]),
        ]
        self.assert_rejected(
            entries,
            "mixed root spelling",
            "duplicate normalized archive member",
            MIXED_ROOT_MAPPING,
            MIXED_ROOT_EXECUTABLES,
        )

    def test_rejects_links_devices_and_fifos(self):
        cases = [
            ([("mailpit", None, 0o755, tarfile.SYMTYPE, "other")] + valid_entries()[1:], "symlink"),
            ([("mailpit", None, 0o755, tarfile.LNKTYPE, "LICENSE")] + valid_entries()[1:], "hard link"),
            ([("mailpit", None, 0o755, tarfile.CHRTYPE, "")] + valid_entries()[1:], "device"),
            ([("mailpit", None, 0o755, tarfile.FIFOTYPE, "")] + valid_entries()[1:], "fifo"),
        ]
        for entries, label in cases:
            self.assert_rejected(entries, label, "non-regular archive member")

    def test_rejects_missing_and_extra_members(self):
        self.assert_rejected(valid_entries()[:-1], "missing member", "archive members do not match mapping")
        self.assert_rejected(
            valid_entries() + [("unexpected", b"x", 0o644)],
            "extra member",
            "archive members do not match mapping",
        )

    def test_rejects_duplicate_destinations(self):
        mapping = dict(MAPPING)
        mapping["README.md"] = mapping["LICENSE"]
        self.assert_rejected(valid_entries(), "duplicate destination", "duplicate destination", mapping)

    def test_rejects_executable_mode_disagreement(self):
        entries = valid_entries()
        entries[0] = ("mailpit", CONTENTS["mailpit"][0], 0o644)
        self.assert_rejected(entries, "executable is not executable", "executable mode mismatch")

        entries = valid_entries()
        entries[1] = ("LICENSE", CONTENTS["LICENSE"][0], 0o755)
        self.assert_rejected(entries, "non-executable is executable", "executable mode mismatch")


if __name__ == "__main__":
    unittest.main()
PY

echo "upstream archive extraction tests passed"
