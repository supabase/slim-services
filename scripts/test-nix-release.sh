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
    if installable.endswith("pinnedProbes"):
        print(os.environ.get("FAKE_PINNED_PROBES", '{"vendor_hash": "https://example.test/vendor-current.tar.gz"}'))
    else:
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
    if os.environ.get("FAKE_HASH_MISMATCH"):
        pinned = release["hashes"]["vendor_hash"]
        print("error: hash mismatch in fixed-output derivation '/nix/store/xxx-auth-vendor.drv':", file=sys.stderr)
        print("         specified: " + pinned, file=sys.stderr)
        print("            got:    sha256-0000000000000000000000000000000000000000000=", file=sys.stderr)
        sys.exit(1)
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

    # Stubs the published-revision lookup the pin seeding step performs via
    # `gh`, the way the fake `nix` above stubs Nix: one `gh api --paginate`
    # call lists release tags, one `gh api .../releases/tags/<tag>` call
    # lists that release's asset names, and `gh release download` places
    # the matched manifest asset. Each of the three can be made to fail
    # independently to exercise the fail-closed paths. Returns the env
    # overrides the test should pass to self.build() to use this fake.
    def write_fake_gh(self, tags, manifest_tag=None, manifest_data=None, asset_name=None,
                       list_fails=False, assets_fail=False, download_fails=False):
        gh = self.fakebin / "gh"
        gh.write_text("#!" + sys.executable + "\n" + '''import json, os, pathlib, shutil, sys
args = sys.argv[1:]
trace_path = os.environ.get("GH_TRACE")
if trace_path:
    with open(trace_path, "a") as trace:
        trace.write(json.dumps(args) + "\\n")
if args[:2] == ["api", "--paginate"]:
    if os.environ.get("FAKE_GH_LIST_FAILS"):
        print("gh: release listing failed", file=sys.stderr)
        sys.exit(1)
    for tag in json.loads(os.environ.get("FAKE_RELEASE_TAGS", "[]")):
        print(tag)
    sys.exit(0)
if args[:1] == ["api"] and len(args) > 1 and "/releases/tags/" in args[1]:
    if os.environ.get("FAKE_GH_ASSETS_FAILS"):
        print("gh: could not list release assets", file=sys.stderr)
        sys.exit(1)
    tag = args[1].rsplit("/releases/tags/", 1)[1]
    expected_tag = os.environ.get("FAKE_RELEASE_TAG_WITH_MANIFEST", "")
    asset = os.environ.get("FAKE_RELEASE_ASSET_NAME", "")
    if asset and tag == expected_tag:
        print(asset)
    sys.exit(0)
if args[:2] == ["release", "download"]:
    if os.environ.get("FAKE_GH_DOWNLOAD_FAILS"):
        print("gh: download failed", file=sys.stderr)
        sys.exit(1)
    tag = args[2]
    expected_tag = os.environ.get("FAKE_RELEASE_TAG_WITH_MANIFEST", "")
    manifest_src = os.environ.get("FAKE_RELEASE_MANIFEST", "")
    asset = os.environ.get("FAKE_RELEASE_ASSET_NAME", "")
    dest = args[args.index("--dir") + 1] if "--dir" in args else None
    if tag == expected_tag and manifest_src and dest:
        pathlib.Path(dest).mkdir(parents=True, exist_ok=True)
        shutil.copy(manifest_src, os.path.join(dest, asset))
        sys.exit(0)
    print("release asset not found: " + tag, file=sys.stderr)
    sys.exit(1)
print("unexpected gh invocation: " + " ".join(args), file=sys.stderr)
sys.exit(1)
''')
        gh.chmod(0o755)
        self.gh_trace = self.repo / "gh-trace.jsonl"
        env = {
            "GH_REPO": "supabase/slim-services",
            "GH_TOKEN": "test-token",
            "GH_TRACE": str(self.gh_trace),
            "FAKE_RELEASE_TAGS": json.dumps(tags),
        }
        if list_fails:
            env["FAKE_GH_LIST_FAILS"] = "1"
        if assets_fail:
            env["FAKE_GH_ASSETS_FAILS"] = "1"
        if download_fails:
            env["FAKE_GH_DOWNLOAD_FAILS"] = "1"
        if manifest_tag:
            manifest_path = self.repo / "fixture-manifest.json"
            manifest_path.write_text(json.dumps(manifest_data))
            env["FAKE_RELEASE_TAG_WITH_MANIFEST"] = manifest_tag
            env["FAKE_RELEASE_MANIFEST"] = str(manifest_path)
            env["FAKE_RELEASE_ASSET_NAME"] = asset_name or f"{manifest_tag}-linux-amd64.manifest.json"
        return env

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
            self.assertEqual(manifest["version"], f"{version}-r0")
            self.assertEqual(manifest["upstream_version"], version)
            self.assertEqual(manifest["revision"], 0)
            self.assertIn("vendor_hash", manifest["nix_derived_hashes"])
            self.assertIsNone(manifest["archive"])
            self.assertEqual((artifact / "rootfs/bin/auth").read_bytes(), (self.runtime / "bin/auth").read_bytes())
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        # Per build: eval pinnedProbes, eval probeOrder, probe vendor_hash,
        # build runtime.
        self.assertEqual(len(calls), 8)
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

    # Default FAKE_PINNED_PROBES URL set by the fake nix above.
    PIN_URL = "https://example.test/vendor-current.tar.gz"

    def test_published_revision_pins_by_key_when_manifest_predates_url_recording(self):
        pinned_hash = "sha256-PinnedPinnedPinnedPinnedPinnedPinnedPinnedAA="
        manifest = {
            "service": "auth", "version": "v1.0.0-r0", "platform": "linux/amd64",
            "nix_derived_hashes": {"vendor_hash": pinned_hash},
        }
        gh_env = self.write_fake_gh(["auth-v1.0.0-r0"], manifest_tag="auth-v1.0.0-r0", manifest_data=manifest)
        result = self.build("v1.0.0", **gh_env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("pinning vendor_hash", result.stdout)
        self.assertIn("URL unrecorded", result.stdout)
        manifest_out = json.loads((self.repo / "artifacts/auth/v1.0.0/linux-amd64/manifest.json").read_text())
        self.assertEqual(manifest_out["nix_derived_hashes"]["vendor_hash"], pinned_hash)
        self.assertEqual(manifest_out["nix_pinned_urls"]["vendor_hash"], self.PIN_URL)
        # The only pinned key (vendor_hash) is seeded from the published
        # manifest, so the probe loop never calls dependencyProbes for it.
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertFalse(any("dependencyProbes" in " ".join(call["args"]) for call in calls))

    def test_pinned_hash_mismatch_fails_the_build_with_a_clear_error_and_does_not_reprobe(self):
        pinned_hash = "sha256-PinnedPinnedPinnedPinnedPinnedPinnedPinnedAA="
        manifest = {
            "service": "auth", "version": "v1.0.0-r0", "platform": "linux/amd64",
            "nix_derived_hashes": {"vendor_hash": pinned_hash},
        }
        gh_env = self.write_fake_gh(["auth-v1.0.0-r0"], manifest_tag="auth-v1.0.0-r0", manifest_data=manifest)
        result = self.build("v1.0.0", FAKE_HASH_MISMATCH="1", **gh_env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[slim] ERROR:", result.stderr)
        self.assertIn("vendor_hash", result.stderr)
        self.assertIn(pinned_hash, result.stderr)
        self.assertIn("auth-v1.0.0-r0", result.stderr)
        self.assertIn(self.PIN_URL, result.stderr)
        self.assertIn("upstream artifact changed", result.stderr)
        self.assertFalse((self.repo / "artifacts/auth/v1.0.0/linux-amd64/rootfs").exists())
        # No fallback re-probe of the pinned key after the mismatch.
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertFalse(any("dependencyProbes" in " ".join(call["args"]) for call in calls))

    def test_no_published_revision_behaves_unchanged(self):
        gh_env = self.write_fake_gh([])
        result = self.build("v1.0.0", **gh_env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertNotIn("pinning vendor_hash", result.stdout)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertTrue(any("dependencyProbes" in " ".join(call["args"]) for call in calls))

    def test_published_release_url_mismatch_skips_pin_and_probes_normally(self):
        pinned_hash = "sha256-PinnedPinnedPinnedPinnedPinnedPinnedPinnedAA="
        manifest = {
            "service": "auth", "version": "v1.0.0-r0", "platform": "linux/amd64",
            "nix_derived_hashes": {"vendor_hash": pinned_hash},
            "nix_pinned_urls": {"vendor_hash": "https://example.test/vendor-OLD.tar.gz"},
        }
        gh_env = self.write_fake_gh(["auth-v1.0.0-r0"], manifest_tag="auth-v1.0.0-r0", manifest_data=manifest)
        result = self.build("v1.0.0", **gh_env)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("URL changed", result.stdout)
        self.assertNotIn("pinning vendor_hash", result.stdout)
        # Not pinned (the recipe moved vendor_hash to a different URL since
        # that release): the probe loop still resolves it itself.
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertTrue(any("dependencyProbes" in " ".join(call["args"]) for call in calls))

    def test_release_listing_failure_fails_closed_without_probing(self):
        gh_env = self.write_fake_gh([], list_fails=True)
        result = self.build("v1.0.0", **gh_env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[slim] ERROR:", result.stderr)
        self.assertIn("could not list published releases", result.stderr)
        self.assertFalse((self.repo / "artifacts/auth/v1.0.0/linux-amd64/rootfs").exists())
        # Fails before the probe loop ever runs: the only Nix call made is
        # the pinnedProbes eval that preceded the (failing) GitHub lookup.
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertEqual(len(calls), 1)

    def test_manifest_download_failure_fails_closed(self):
        pinned_hash = "sha256-PinnedPinnedPinnedPinnedPinnedPinnedPinnedAA="
        manifest = {
            "service": "auth", "version": "v1.0.0-r0", "platform": "linux/amd64",
            "nix_derived_hashes": {"vendor_hash": pinned_hash},
        }
        gh_env = self.write_fake_gh(["auth-v1.0.0-r0"], manifest_tag="auth-v1.0.0-r0",
                                     manifest_data=manifest, download_fails=True)
        result = self.build("v1.0.0", **gh_env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("[slim] ERROR:", result.stderr)
        self.assertIn("could not download", result.stderr)
        self.assertIn("auth-v1.0.0-r0", result.stderr)
        self.assertFalse((self.repo / "artifacts/auth/v1.0.0/linux-amd64/rootfs").exists())
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()]
        self.assertEqual(len(calls), 1)

unittest.main()
PY
