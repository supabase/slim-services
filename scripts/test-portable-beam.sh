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
LAUNCHER = ROOT_DIR / "nix" / "portable-beam" / "beam-launcher.sh"
FIXUP = ROOT_DIR / "nix" / "portable-beam" / "beam-linux-fixup.sh"
BUILD = ROOT_DIR / "scripts" / "build-artifact-from-nix.sh"


class PortableBeamLauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LAUNCHER.is_file():
            raise RuntimeError(
                "portable-beam launcher seam is absent; baseline still exposes host-loader ERTS ELFs"
            )

    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-portable-beam."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.rootfs = self.temp / "rootfs"
        self.vm_dir = self.rootfs / "erts-14.2.5" / "bin"
        self.vm_dir.mkdir(parents=True)
        self.rootfs.joinpath("dylib").mkdir()
        self.lib_dir = self.rootfs / "lib"
        self.lib_dir.mkdir()
        (self.lib_dir / "gconv").mkdir()
        (self.lib_dir / "locale").mkdir()
        (self.lib_dir / "locale" / "locale-archive").write_text("fixture", encoding="utf-8")
        self.trace = self.temp / "loader.trace"
        self.vm_args = self.temp / "vm.args"
        self.port_args = self.temp / "port.args"
        self.vm_env = self.temp / "vm.env"
        self.port_env = self.temp / "port.env"
        self.vm = self.vm_dir / ".beam.smp-real"
        self.port = self.vm_dir / ".inet_gethost-real"
        self._write_real(self.vm, self.vm_args, self.vm_env, output="vm-ok\n")
        self._write_real(self.port, self.port_args, self.port_env, output=None)

        loader = self.lib_dir / "ld-linux-x86-64.so.2"
        loader.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "argv0=\n"
            "if [ \"${1:-}\" = --argv0 ]; then argv0=$2; shift 2; fi\n"
            "[ \"${1:-}\" = --library-path ] || exit 41\n"
            "library_path=$2\n"
            "shift 2\n"
            "real=$1\n"
            "shift\n"
            ": > \"$TRACE\"\n"
            "printf 'argv0=%s\\nlibrary-path=%s\\nreal=%s\\n' \"$argv0\" \"$library_path\" \"$real\" >> \"$TRACE\"\n"
            "exec \"$real\" \"$@\"\n",
            encoding="utf-8",
        )
        loader.chmod(0o755)

        self.vm_launcher = self.vm_dir / "beam.smp"
        self.port_launcher = self.vm_dir / "inet_gethost"
        template = LAUNCHER.read_text(encoding="utf-8")
        for public, real in ((self.vm_launcher, self.vm), (self.port_launcher, self.port)):
            generated = (
                template.replace("@LOADER_NAME@", loader.name)
                .replace("@ROOT_REL@", "../..")
                .replace("@REAL_NAME@", real.name)
                .replace("@ARGV0_SUPPORTED@", "1")
            )
            public.write_text(generated, encoding="utf-8")
            public.chmod(0o755)

    @staticmethod
    def _write_real(path, args_path, env_path, output):
        output_code = ""
        if output is not None:
            output_code = f"printf '%s' {output!r}\n"
        else:
            output_code = "while IFS= read -r line; do printf '%s\\n' \"$line\"; done\n"
        path.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            ": > \"$ARGS_PATH\"\n"
            "printf '%s\\n' \"$@\" >> \"$ARGS_PATH\"\n"
            "printf '%s\\n' \"${LD_LIBRARY_PATH-unset}\" \"${LD_PRELOAD-unset}\" \"${GLIBC_TUNABLES-unset}\" \"${GCONV_PATH-unset}\" \"${LOCALE_ARCHIVE-unset}\" > \"$ENV_PATH\"\n"
            + output_code,
            encoding="utf-8",
        )
        path.chmod(0o755)

    def run_launcher(self, launcher, args=(), stdin=None, root=None):
        root = pathlib.Path(root or self.rootfs)
        relative = launcher.relative_to(self.rootfs)
        launcher = root / relative
        env = {
            **os.environ,
            "PATH": "/nonexistent",
            "TRACE": str(self.trace),
            "ARGS_PATH": str(self.vm_args if launcher.name == "beam.smp" else self.port_args),
            "ENV_PATH": str(self.vm_env if launcher.name == "beam.smp" else self.port_env),
            "LD_LIBRARY_PATH": "/host/glibc",
            "GCONV_PATH": "/host/gconv",
            "LOCALE_ARCHIVE": "/host/locale-archive",
            "LD_PRELOAD": "/host/preload.so",
            "GLIBC_TUNABLES": "glibc.malloc.check=3",
        }
        command = [str(launcher)] if pathlib.Path("/usr/bin/sh").exists() else ["/bin/sh", str(launcher)]
        return subprocess.run(
            [*command, *args],
            cwd=ROOT_DIR,
            env=env,
            input=stdin,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_vm_launcher_uses_relative_loader_and_preserves_identity(self):
        result = self.run_launcher(self.vm_launcher, args=("--smp", "2"))
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8").splitlines()
        root = self.rootfs.resolve()
        self.assertEqual(trace[0], f"argv0={self.vm_launcher}")
        self.assertEqual(trace[1], f"library-path={root / 'lib'}:{root / 'dylib'}")
        self.assertEqual(trace[2], f"real={self.vm}")
        self.assertEqual(self.vm_args.read_text(encoding="utf-8").splitlines(), ["--smp", "2"])
        self.assertEqual(
            self.vm_env.read_text(encoding="utf-8").splitlines(),
            [
                "unset",
                "unset",
                "unset",
                str((self.lib_dir / "gconv").resolve()),
                str((self.lib_dir / "locale" / "locale-archive").resolve()),
            ],
        )

    def test_launcher_clears_side_data_without_artifact_payload(self):
        shutil.rmtree(self.lib_dir / "gconv")
        (self.lib_dir / "locale" / "locale-archive").unlink()
        result = self.run_launcher(self.vm_launcher)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.vm_env.read_text(encoding="utf-8").splitlines(),
            ["unset", "unset", "unset", "unset", "unset"],
        )

    def test_port_launcher_transparently_round_trips_stdin_stdout(self):
        result = self.run_launcher(self.port_launcher, stdin="lookup example\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "lookup example\n")
        self.assertEqual(self.port_args.read_text(encoding="utf-8").strip(), "")

    def test_launchers_relocate_with_extracted_root(self):
        relocated = self.temp / "relocated root"
        shutil.copytree(self.rootfs, relocated)
        result = self.run_launcher(self.vm_launcher, root=relocated)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str((relocated / "lib").resolve()), self.trace.read_text(encoding="utf-8"))

    def test_missing_loader_and_real_binary_fail_loudly(self):
        loader = self.lib_dir / "ld-linux-x86-64.so.2"
        loader.unlink()
        result = self.run_launcher(self.vm_launcher)
        self.assertEqual(result.returncode, 127)
        self.assertIn("bundled loader is missing", result.stderr)

        loader.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        loader.chmod(0o755)
        self.vm.unlink()
        result = self.run_launcher(self.vm_launcher)
        self.assertEqual(result.returncode, 127)
        self.assertIn("real BEAM executable is missing", result.stderr)

    def test_generated_launcher_uses_image_sh_path(self):
        self.assertEqual(LAUNCHER.read_text(encoding="utf-8").splitlines()[0], "#!/usr/bin/sh")

    def test_pinned_notice_extraction_consumes_tar_under_pipefail(self):
        source_tree = self.temp / "notice-tree"
        source_tree.mkdir()
        (source_tree / "LICENSE").write_text("tzdata fixture license\n", encoding="utf-8")
        for index in range(2048):
            (source_tree / f"payload-{index:04d}").write_text("x", encoding="utf-8")
        archive = self.temp / "notices.tar"
        subprocess.run(["tar", "-cf", str(archive), "."], cwd=source_tree, check=True)
        extracted = self.temp / "extracted-license"
        pipeline = r'''set -euo pipefail
notice_member="$(tar -tf "$1" | awk -v notice=LICENSE -v suffix=/LICENSE '
  selected == "" && ($0 == notice || (length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix)) {
    selected = $0
  }
  END { if (selected != "") print selected }
')"
[ "$notice_member" = ./LICENSE ]
tar -xOf "$1" "$notice_member" > "$2"
'''
        result = subprocess.run(
            ["bash", "-c", pipeline, "notice-pipeline", str(archive), str(extracted)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(extracted.read_text(encoding="utf-8"), "tzdata fixture license\n")

    def test_shared_seam_is_wired_into_local_and_docker_nix_exports(self):
        self.assertTrue(FIXUP.is_file())
        build_text = BUILD.read_text(encoding="utf-8")
        self.assertIn("NIX_AUXILIARY_OVERLAYS", build_text)
        for service in ("realtime", "pooler", "analytics"):
            recipe = (ROOT_DIR / "services" / service / "recipe.env").read_text(encoding="utf-8")
            self.assertIn('"nix/portable-beam:nix/portable-beam"', recipe)
            dockerfile = (ROOT_DIR / "services" / service / "Dockerfile.artifact").read_text(encoding="utf-8")
            self.assertIn("COPY nix/portable-beam/ nix/portable-beam/", dockerfile)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PortableBeamLauncherTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
PY
