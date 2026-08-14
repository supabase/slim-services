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
BUILD = ROOT_DIR / "scripts" / "build-artifact-from-nix.sh"


class ExternalSourceBuildTest(unittest.TestCase):
    def setUp(self):
        self.version = f"9.9.{os.getpid()}"
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-external-source-build."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.bash_env = self.temp / "bash-env"
        self.trace = self.temp / "nix-build.argv"
        self.policy = self.temp / "snapshot.json"
        self.write_snapshot()
        self.write_fake_nix()
        self.artifact = ROOT_DIR / "artifacts" / "vector" / self.version / "darwin-arm64"
        self.linux_artifact = ROOT_DIR / "artifacts" / "vector" / self.version / "linux-amd64"
        shutil.rmtree(self.artifact, ignore_errors=True)
        shutil.rmtree(self.linux_artifact, ignore_errors=True)
        self.addCleanup(shutil.rmtree, self.artifact, ignore_errors=True)
        self.addCleanup(shutil.rmtree, self.linux_artifact, ignore_errors=True)

    def write_snapshot(self):
        self.policy.write_text(
            json.dumps(
                {
                    "repository": "acme/vector",
                    "versions": {
                        self.version: {
                            "release_tag": f"v{self.version}",
                            "source": {
                                "commit": "a" * 40,
                                "url": "https://github.com/acme/vector/archive/" + "a" * 40 + ".tar.gz",
                                "sha256": "b" * 64,
                                "fetch_from_github_hash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                                "vendorHash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                            },
                            "image": {
                                "source": f"docker.io/acme/vector:{self.version}",
                                "index_digest": "sha256:" + "c" * 64,
                                "platforms": {
                                    "linux/amd64": "sha256:" + "d" * 64,
                                    "linux/arm64": "sha256:" + "e" * 64,
                                },
                            },
                        }
                    },
                }
            ),
            encoding="utf-8",
        )

    def write_fake_nix(self):
        self.bash_env.write_text(
            "nix() {\n"
            "  if [[ ${1:-} == eval ]]; then printf '%s\\n' aarch64-darwin; return 0; fi\n"
            "  printf '%s\\n' \"$@\" > \"$FAKE_NIX_TRACE\"\n"
            "  return 0\n"
            "}\n"
            "nix-build() {\n"
            "  printf '%s\\n' \"$@\" > \"$FAKE_NIX_TRACE\"\n"
            "  local out=''\n"
            "  while [[ $# -gt 0 ]]; do\n"
            "    if [[ $1 == --out-link ]]; then out=$2; shift 2; else shift; fi\n"
            "  done\n"
            "  [[ -n $out ]]\n"
            "  mkdir -p \"$out/bin\"\n"
            "  printf '%s\\n' fixture > \"$out/bin/vector\"\n"
            "  chmod 0755 \"$out/bin/vector\"\n"
            "}\n",
            encoding="utf-8",
        )
        (self.bin / "nix").write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${1:-} == eval ]]; then printf '%s\\n' aarch64-darwin; exit 0; fi\n"
            "exit 1\n",
            encoding="utf-8",
        )
        (self.bin / "nix-build").write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf '%s\\n' \"$@\" > \"$FAKE_NIX_TRACE\"\n"
            "out=''\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  if [[ $1 == --out-link ]]; then out=$2; shift 2; else shift; fi\n"
            "done\n"
            "[[ -n $out ]]\n"
            "mkdir -p \"$out/bin\"\n"
            "printf '%s\\n' fixture > \"$out/bin/vector\"\n"
            "chmod 0755 \"$out/bin/vector\"\n",
            encoding="utf-8",
        )
        for path in (self.bin / "nix", self.bin / "nix-build"):
            path.chmod(0o755)

    def env(self, mapping=None):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}:{env['PATH']}",
                "UPSTREAM_ASSETS_FILE": str(self.policy),
                "NIX_SOURCE_ARGS_JSON": json.dumps(
                    {
                        "serviceVersion": "version",
                        "sourceRepository": "repository",
                        "sourceCommit": "source.commit",
                        "sourceHash": "source.fetch_from_github_hash",
                        "vendorHash": "source.vendorHash",
                    }
                    if mapping is None
                    else mapping
                ),
                "TARGET_OS": "darwin",
                "ARCH": "arm64",
                "NIX_RUNNER": "local",
                "NIX_BUILD_MODE": "nix-build",
                "NIX_EXPRESSION": ".",
                "NIX_FLAKE": ".",
                "NIX_ATTR": "fixture",
                "NIX_OUTPUT_KIND": "rootfs",
                "BASE_IMAGE": "scratch",
                "ENTRYPOINT_JSON": "[]",
                "CMD_JSON": "[\"/bin/vector\"]",
                "ARTIFACT_ARCHIVE_ON_BUILD": "0",
                "FAKE_NIX_TRACE": str(self.trace),
                "BASH_ENV": str(self.bash_env),
            }
        )
        return env

    def run_build(self, mapping=None, **env_overrides):
        environment = self.env(mapping)
        environment.update(env_overrides)
        return subprocess.run(
            ["bash", str(BUILD), "vector", self.version],
            cwd=ROOT_DIR,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_passes_ordered_generic_source_values_to_nix_and_records_them(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.trace.read_text(encoding="utf-8").splitlines()
        expected = [
            "-A",
            "fixture",
            "--argstr",
            "serviceVersion",
            self.version,
            "--argstr",
            "sourceRepository",
            "acme/vector",
            "--argstr",
            "sourceCommit",
            "a" * 40,
            "--argstr",
            "sourceHash",
            "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "--argstr",
            "vendorHash",
            "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        ]
        self.assertEqual(args[1 : 1 + len(expected)], expected)
        self.assertEqual(args[1 + len(expected)], "--out-link")
        manifest = json.loads((self.artifact / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["upstream_source"]["commit"], "a" * 40)
        self.assertEqual(manifest["upstream_source_repository"], "acme/vector")
        self.assertEqual(
            manifest["nix_source_args"],
            {
                "serviceVersion": "version",
                "sourceRepository": "repository",
                "sourceCommit": "source.commit",
                "sourceHash": "source.fetch_from_github_hash",
                "vendorHash": "source.vendorHash",
            },
        )

    def test_rejects_unknown_selector_before_invoking_nix(self):
        result = self.run_build({"sourceCommit": "source.not_a_field"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown source selector", result.stderr)
        self.assertFalse(self.trace.exists())

    def test_rejects_unsafe_nix_argument_name(self):
        result = self.run_build({"source-commit": "source.commit"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe Nix argument", result.stderr)
        self.assertFalse(self.trace.exists())

    def test_rejects_empty_or_malformed_mapping(self):
        result = self.run_build({})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-empty JSON object", result.stderr)
        self.assertFalse(self.trace.exists())

        result = self.run_build({"sourceCommit": 7})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsafe source selector", result.stderr)
        self.assertFalse(self.trace.exists())

        result = self.run_build(
            NIX_SOURCE_ARGS_JSON='{"sourceCommit":"source.commit","sourceCommit":"source.sha256"}'
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate Nix argument name", result.stderr)
        self.assertFalse(self.trace.exists())

    def test_rejects_external_flake_mode_before_nix_execution(self):
        result = self.run_build(NIX_BUILD_MODE="flake")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NIX_BUILD_MODE=nix-build", result.stderr)
        self.assertFalse(self.trace.exists())
        self.assertFalse((self.artifact / "manifest.json").exists())

    def test_rejects_external_custom_template_before_execution(self):
        result = self.run_build(NIX_BUILD_COMMAND_TEMPLATE="printf should-not-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NIX_BUILD_COMMAND_TEMPLATE", result.stderr)
        self.assertFalse(self.trace.exists())
        self.assertFalse((self.artifact / "manifest.json").exists())

    def test_rejects_external_docker_runner_before_execution(self):
        result = self.run_build(
            TARGET_OS="linux",
            ARCH="amd64",
            NIX_RUNNER="docker",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NIX_RUNNER=local", result.stderr)
        self.assertFalse(self.trace.exists())
        self.assertFalse((self.linux_artifact / "manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
PY

echo "external source build tests passed"
