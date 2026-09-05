#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(sys.argv[1])
sys.argv[1:] = []

class NativeReleaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="slim-nix-release-test.")
        self.addCleanup(self.tmp.cleanup)
        self.repo = pathlib.Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        (self.repo / "scripts").symlink_to(ROOT / "scripts")
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            (self.repo / name).symlink_to(ROOT / name)
        service = self.repo / "services/auth"
        service.mkdir(parents=True)
        (service / "recipe.env").write_text('SOURCE_DIR="sources/auth"\nSOURCE_REF="${SOURCE_REF:-v1.0.0}"\nARTIFACT_BACKEND="nix"\nPORTABLE="true"\nENTRYPOINT_JSON=\'[]\'\nCMD_JSON=\'["auth"]\'\n')
        self.source = self.repo / "sources/auth"
        self.source.mkdir(parents=True)
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.test")
        self.commit("v1.0.0")
        self.runtime = self.repo / "runtime"
        (self.runtime / "bin").mkdir(parents=True)
        (self.runtime / "bin/auth").write_text("#!/bin/sh\necho fixture\n")
        (self.runtime / "bin/auth").chmod(0o755)
        self.fakebin = self.repo / "fakebin"
        self.fakebin.mkdir()
        nix = self.fakebin / "nix"
        nix.write_text("#!" + sys.executable + "\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
release_dir = args[args.index("--override-input") + 2].removeprefix("path:")
release = json.loads((pathlib.Path(release_dir) / "release.json").read_text())
installable = next(a for a in args if "#" in a)
with open(os.environ["NIX_TRACE"], "a") as trace:
    trace.write(json.dumps({"args": args, "release": release}) + "\\n")
if "eval" in args:
    print('["vendor_hash"]')
elif "dependencyProbes" in installable:
    if os.environ.get("PROBE_BROKEN"):
        print("source dependency fetch failed", file=sys.stderr)
    else:
        print("hash mismatch: got: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", file=sys.stderr)
    sys.exit(1)
else:
    assert "vendor_hash" in release["hashes"]
    assert (pathlib.Path(release_dir) / "source/version.txt").read_text() == release["version"]
    print(os.environ["NIX_RUNTIME"])
''')
        nix.chmod(0o755)
        self.trace = self.repo / "trace.jsonl"
        self.env = dict(os.environ, PATH=f"{self.fakebin}:{os.environ['PATH']}",
                        NIX_TRACE=str(self.trace), NIX_RUNTIME=str(self.runtime),
                        TARGET_OS="linux", ARCH="amd64", ARTIFACT_ARCHIVE_ON_BUILD="0")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args], text=True).strip()

    def commit(self, version):
        (self.source / "version.txt").write_text(version)
        self.git("add", "version.txt")
        self.git("commit", "-qm", version)
        self.git("tag", version)
        return self.git("rev-parse", "HEAD")

    def build(self, version="v1.0.0", **env):
        return subprocess.run(["bash", str(self.repo / "scripts/build-artifact.sh"), "auth", version],
                              env=dict(self.env, SOURCE_REF=version, **env), text=True, capture_output=True)

    def test_new_version_resolves_hashes_and_builds_without_a_repository_lock_update(self):
        for version in ("v1.0.0", "v1.1.0"):
            if version == "v1.1.0":
                self.commit(version)
            result = self.build(version)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            artifact = self.repo / "artifacts/auth" / version / "linux-amd64"
            manifest = json.loads((artifact / "manifest.json").read_text())
            self.assertEqual(manifest["source_commit"], self.git("rev-parse", "HEAD"))
            self.assertEqual(manifest["nix_release"]["version"], version)
            self.assertIn("vendor_hash", manifest["nix_derived_hashes"])
            self.assertIsNone(manifest["archive"])
            self.assertEqual((artifact / "rootfs/bin/auth").read_bytes(), (self.runtime / "bin/auth").read_bytes())
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertEqual(len(calls), 6)
        self.assertTrue(all("--impure" not in call["args"] for call in calls))
        self.assertTrue(all("--no-write-lock-file" in call["args"] for call in calls))

    def test_real_probe_failure_stops_before_the_runtime_build(self):
        result = self.build(PROBE_BROKEN="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Nix failed without resolving", result.stderr)
        self.assertFalse((self.repo / "artifacts/auth/v1.0.0/linux-amd64/rootfs").exists())

    def test_dirty_source_is_rejected_before_nix_runs(self):
        (self.source / "version.txt").write_text("modified")
        result = self.build()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local modifications", result.stderr)
        self.assertFalse(self.trace.exists())

    def test_wrong_source_commit_is_rejected_before_nix_runs(self):
        self.commit("v1.1.0")
        result = self.build("v1.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected v1.0.0", result.stderr)
        self.assertFalse(self.trace.exists())

unittest.main()
PY
