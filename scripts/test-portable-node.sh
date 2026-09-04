#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import os
import io
import pathlib
import shutil
import subprocess
import tempfile
import tarfile
import unittest


ROOT_DIR = pathlib.Path(os.sys.argv[1])
os.sys.argv[1:] = []
LAUNCHER = ROOT_DIR / "nix" / "portable-node" / "node-launcher.sh"
PRELOAD = ROOT_DIR / "nix" / "portable-node" / "node-execpath.cjs"
NOTICE_HELPER = ROOT_DIR / "nix" / "portable-node" / "copy-source-notice.sh"


class PortableNodeLauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LAUNCHER.is_file() or not PRELOAD.is_file():
            raise RuntimeError(
                "portable-node launcher seam is absent; baseline still exposes only the host-glibc Node ELF"
            )

    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-portable-node."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.rootfs = self.temp / "rootfs"
        self.node_root = self.rootfs / "node"
        (self.node_root / "bin").mkdir(parents=True)
        (self.node_root / "dylib").mkdir()
        (self.rootfs / "lib").mkdir()
        (self.rootfs / "lib" / "gconv").mkdir()
        (self.rootfs / "lib" / "locale").mkdir()
        (self.rootfs / "lib" / "locale" / "locale-archive").write_text(
            "fixture", encoding="utf-8"
        )
        launcher = (LAUNCHER.read_text(encoding="utf-8")).replace(
            "@LOADER_NAME@", "ld-linux-x86-64.so.2"
        )
        (self.node_root / "bin" / "node").write_text(launcher, encoding="utf-8")
        shutil.copy2(PRELOAD, self.node_root / "bin" / ".node-execpath.cjs")
        (self.node_root / "bin" / "node").chmod(0o755)
        self.trace = self.temp / "loader.trace"
        self.real_args = self.temp / "real.args"
        self.real_env = self.temp / "real.env"
        self.real_side_data = self.temp / "real.side-data"
        self.real_wrapper = self.temp / "real.wrapper"
        self.loader = self.rootfs / "lib" / "ld-linux-x86-64.so.2"
        self.loader.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "printf '%s\\n' \"$@\" > \"$TRACE\"\n"
            "[ \"${1:-}\" = --library-path ] || exit 41\n"
            "shift 2\n"
            "real=\"$1\"\n"
            "shift\n"
            "exec \"$real\" \"$@\"\n",
            encoding="utf-8",
        )
        self.loader.chmod(0o755)
        self.real = self.node_root / "bin" / ".node-real"
        self.real.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            ": > \"$REAL_ARGS\"\n"
            "printf '%s\\n' \"$@\" >> \"$REAL_ARGS\"\n"
            "printf '%s\\n' \"${LD_LIBRARY_PATH-unset}\" > \"$REAL_ENV\"\n"
            "printf '%s\\n' \"${GCONV_PATH-unset}\n${LOCALE_ARCHIVE-unset}\" > \"$REAL_SIDE_DATA\"\n"
            "printf '%s\\n' \"${SLIM_NODE_WRAPPER-unset}\" > \"$REAL_WRAPPER\"\n",
            encoding="utf-8",
        )
        self.real.chmod(0o755)

    def run_launcher(self, root=None, args=()):
        root = pathlib.Path(root or self.rootfs)
        env = {
            **os.environ,
            "PATH": "/nonexistent",
            "TRACE": str(self.trace),
            "REAL_ARGS": str(self.real_args),
            "REAL_ENV": str(self.real_env),
            "REAL_SIDE_DATA": str(self.real_side_data),
            "REAL_WRAPPER": str(self.real_wrapper),
            "LD_LIBRARY_PATH": "/host/glibc",
            "GCONV_PATH": "/host/gconv",
            "LOCALE_ARCHIVE": "/host/locale-archive",
        }
        launcher = root / "node" / "bin" / "node"
        # macOS lacks the image-provided /usr/bin/sh; invoke the exact
        # template through the host shell there while preserving its image
        # shebang assertion above.
        command = [str(launcher)] if pathlib.Path("/usr/bin/sh").exists() else ["/bin/sh", str(launcher)]
        return subprocess.run(
            [*command, *args],
            cwd=ROOT_DIR,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def make_symlink_image(self, real_node=None):
        image_root = self.temp / "image"
        runtime_root = image_root / "slim-runtime"
        shutil.copytree(self.rootfs, runtime_root, symlinks=True)
        (image_root / "node").symlink_to("slim-runtime/node")
        if not pathlib.Path("/usr/bin/sh").exists():
            fixture_launcher = runtime_root / "node" / "bin" / "node"
            fixture_launcher.write_text(
                fixture_launcher.read_text(encoding="utf-8").replace(
                    "#!/usr/bin/sh", "#!/bin/sh", 1
                ),
                encoding="utf-8",
            )
        if real_node is not None:
            real = runtime_root / "node" / "bin" / ".node-real"
            real.unlink()
            shutil.copy2(real_node, real)
            real.chmod(0o755)
        return image_root, runtime_root

    def test_relative_loader_and_library_path_are_artifact_owned(self):
        result = self.run_launcher(args=("--eval", "fixture"))
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8").splitlines()
        rootfs = self.rootfs.resolve()
        node_root = self.node_root.resolve()
        self.assertEqual(trace[0], "--library-path")
        self.assertEqual(trace[1], f"{rootfs}/lib:{node_root}/dylib")
        self.assertEqual(trace[2], str(self.real.resolve()))
        self.assertEqual(trace[3], "--require")
        self.assertEqual(trace[4], str((self.node_root / "bin" / ".node-execpath.cjs").resolve()))
        self.assertEqual(trace[5:], ["--eval", "fixture"])
        self.assertEqual(self.real_env.read_text(encoding="utf-8").strip(), "unset")
        self.assertEqual(
            self.real_side_data.read_text(encoding="utf-8").splitlines(),
            [str((self.rootfs / "lib" / "gconv").resolve()), str((self.rootfs / "lib" / "locale" / "locale-archive").resolve())],
        )

    def test_symlink_image_uses_isolated_loader_and_public_wrapper_identity(self):
        image_root, runtime_root = self.make_symlink_image()
        result = self.run_launcher(image_root, args=("--eval", "fixture"))
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            trace[1],
            f"{runtime_root.resolve()}/lib:{(runtime_root / 'node' / 'dylib').resolve()}",
        )
        self.assertEqual(
            self.real_wrapper.read_text(encoding="utf-8").strip(),
            str(image_root / "node" / "bin" / "node"),
        )
        self.assertEqual(
            self.real_side_data.read_text(encoding="utf-8").splitlines(),
            [
                str((runtime_root / "lib" / "gconv").resolve()),
                str((runtime_root / "lib" / "locale" / "locale-archive").resolve()),
            ],
        )

    def test_linux_postfixup_seeds_pinned_compiler_runtime(self):
        nix = shutil.which("nix")
        if not nix:
            self.skipTest("Nix is required for the staged compiler-runtime assertion")
        expression = r'''
let
  fakeLib = {
    optionalString = condition: value: if condition then value else "";
    optionals = condition: values: if condition then values else [];
    getLib = package: package.lib;
  };
  fakeStdenv = {
    isLinux = true;
    isDarwin = false;
    cc = {
      cc = {
        lib = "/tmp/pinned-gcc-lib";
        libgcc = "/tmp/pinned-gcc-libgcc";
        src = "/tmp/pinned-gcc.tar.xz";
        version = "14.3.0";
      };
    };
    mkDerivation = attrs: attrs // { name = "portable-node-fixture"; };
  };
  fakePkgs = {
    lib = fakeLib;
    stdenv = fakeStdenv;
    file = "/bin/file";
    python3 = "/usr/bin/python3";
    patchelf = "/bin/patchelf";
    binutils = "/bin/binutils";
    glibc = {
      __toString = _: "/tmp/pinned-glibc";
      src = "/tmp/pinned-glibc.tar.xz";
      version = "2.40";
    };
    glibcLocales = { override = _: "/tmp/pinned-glibc-locales"; };
    nodejs_24 = { version = "24.11.1"; };
  };
in (import ./nix/portable-node/default.nix { pkgs = fakePkgs; nodeMajor = 24; }).postFixup
'''
        result = subprocess.run(
            [nix, "eval", "--impure", "--raw", "--expr", expression],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/tmp/pinned-gcc-lib", result.stdout)
        self.assertIn("libstdc++.so.6", result.stdout)
        self.assertIn("libgcc_s.so.1", result.stdout)
        self.assertIn("share/licenses/portable-node", result.stdout)
        self.assertIn("COPYING.LIB", result.stdout)
        self.assertIn("COPYING.RUNTIME", result.stdout)
        self.assertIn("COPYING3", result.stdout)
        self.assertIn("copy-source-notice.sh", result.stdout)

    def test_notice_copy_consumes_complete_tar_stream_under_pipefail(self):
        archive = self.temp / "notice.tar"
        with tarfile.open(archive, "w") as tar:
            license_payload = b"license fixture\n"
            license_info = tarfile.TarInfo("source/COPYING.LIB")
            license_info.size = len(license_payload)
            tar.addfile(license_info, io.BytesIO(license_payload))
            for index in range(4096):
                trailing_payload = f"trailing-{index}\n".encode("ascii")
                trailing_info = tarfile.TarInfo(f"source/trailing-{index:04d}.txt")
                trailing_info.size = len(trailing_payload)
                tar.addfile(trailing_info, io.BytesIO(trailing_payload))
        destination = self.temp / "copied" / "COPYING.LIB"
        destination.parent.mkdir()
        real_tar = shutil.which("tar")
        if not real_tar:
            self.skipTest("tar is required for the notice-stream regression")
        shim_dir = self.temp / "tar-bin"
        shim_dir.mkdir()
        tar_shim = shim_dir / "tar"
        tar_shim.write_text(
            "#!" + os.sys.executable + "\n"
            "import os, subprocess, sys\n"
            "real_tar = os.environ['REAL_TAR']\n"
            "if sys.argv[1:2] == ['-tf']:\n"
            "    producer = subprocess.Popen([real_tar, '-tf', sys.argv[2]], stdout=subprocess.PIPE)\n"
            "    try:\n"
            "        for line in producer.stdout:\n"
            "            os.write(1, line)\n"
            "    except BrokenPipeError:\n"
            "        producer.kill()\n"
            "        raise SystemExit(141)\n"
            "    raise SystemExit(producer.wait())\n"
            "os.execv(real_tar, [real_tar, *sys.argv[1:]])\n",
            encoding="utf-8",
        )
        tar_shim.chmod(0o755)
        result = subprocess.run(
            ["bash", str(NOTICE_HELPER), str(archive), "COPYING.LIB", str(destination)],
            text=True,
            capture_output=True,
            env={
                **os.environ,
                "PATH": f"{shim_dir}:{os.defpath}",
                "REAL_TAR": real_tar,
            },
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(destination.read_text(encoding="utf-8"), "license fixture\n")

    def test_image_mounts_portable_runtime_without_overwriting_system_lib(self):
        for service in ("storage", "studio", "pgmeta"):
            dockerfile = ROOT_DIR / "services" / service / "Dockerfile.slim"
            content = dockerfile.read_text(encoding="utf-8")
            with self.subTest(service=service):
                self.assertIn("ln -s /slim-runtime/node /out/node", content)
                self.assertIn(
                    "COPY ${ARTIFACT_ROOT}/node/ /slim-runtime/node/", content
                )
                self.assertIn(
                    "COPY ${ARTIFACT_ROOT}/lib/ /slim-runtime/lib/", content
                )
                self.assertNotIn("COPY ${ARTIFACT_ROOT}/node/ /node/", content)
                self.assertNotIn("COPY ${ARTIFACT_ROOT}/lib/ /lib/", content)

    def test_host_builds_copy_portable_runtime_notices(self):
        for service in ("storage", "studio", "pgmeta"):
            build_host = ROOT_DIR / "services" / service / "build-host.sh"
            content = build_host.read_text(encoding="utf-8")
            with self.subTest(service=service):
                self.assertIn('cp -R "$node_bundle/share/licenses"/. "$ROOTFS/share/licenses/"', content)

    def test_launcher_clears_poisoned_side_data_without_artifact_payload(self):
        shutil.rmtree(self.rootfs / "lib" / "gconv")
        (self.rootfs / "lib" / "locale" / "locale-archive").unlink()
        result = self.run_launcher(args=("--version",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.real_side_data.read_text(encoding="utf-8").splitlines(),
            ["unset", "unset"],
        )

    def test_generated_launcher_uses_image_sh_path(self):
        self.assertEqual(LAUNCHER.read_text(encoding="utf-8").splitlines()[0], "#!/usr/bin/sh")

    def test_launcher_relocates_with_the_extracted_root(self):
        relocated = self.temp / "relocated root"
        shutil.copytree(self.rootfs, relocated)
        result = self.run_launcher(relocated, args=("--version",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str((relocated / "lib").resolve()), self.trace.read_text(encoding="utf-8"))
        self.assertIn(str((relocated / "node" / "dylib").resolve()), self.trace.read_text(encoding="utf-8"))

    def test_missing_loader_and_real_binary_fail_loudly(self):
        self.loader.unlink()
        result = self.run_launcher(args=())
        self.assertEqual(result.returncode, 127)
        self.assertIn("bundled loader is missing", result.stderr)

        self.loader.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        self.loader.chmod(0o755)
        self.real.unlink()
        result = self.run_launcher(args=())
        self.assertEqual(result.returncode, 127)
        self.assertIn("real Node ELF is missing", result.stderr)

    def test_execpath_preload_reenters_wrapper_when_node_is_available(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("a host Node executable is required for the fork proof")
        wrapper = self.temp / "node-wrapper"
        wrapper.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"$TRACE\"\n"
            f"exec {node!r} --require {str(PRELOAD)!r} \"$@\"\n",
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        child = self.temp / "child.cjs"
        child.write_text("process.send({execPath: process.execPath});\n", encoding="utf-8")
        parent = (
            "const cp = require('node:child_process');"
            "const child = cp.fork(process.argv[1], [], {stdio: ['ignore', 'ignore', 'pipe', 'ipc']});"
            "child.on('message', (m) => {"
            "  if (m.execPath !== process.env.SLIM_NODE_WRAPPER) process.exitCode = 2;"
            "});"
            "child.on('exit', (code) => { if (code) process.exitCode = code; });"
        )
        result = subprocess.run(
            [node, "--require", str(PRELOAD), "-e", parent, str(child)],
            env={
                **os.environ,
                "TRACE": str(self.trace),
                "SLIM_NODE_WRAPPER": str(wrapper),
            },
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.trace.read_text(encoding="utf-8").strip())

    def test_symlink_image_fork_reenters_public_wrapper(self):
        node_command = shutil.which("node")
        if not node_command:
            self.skipTest("a host Node executable is required for the fork proof")
        node_result = subprocess.run(
            [node_command, "-p", "process.execPath"],
            text=True,
            capture_output=True,
            check=False,
        )
        node = node_result.stdout.strip()
        if node_result.returncode or not node or not pathlib.Path(node).is_file():
            self.skipTest("a host Node executable is required for the fork proof")
        image_root, runtime_root = self.make_symlink_image(real_node=node)
        public_wrapper = image_root / "node" / "bin" / "node"
        expected_gconv = (runtime_root / "lib" / "gconv").resolve()
        expected_locale = (runtime_root / "lib" / "locale" / "locale-archive").resolve()
        child = self.temp / "symlink-child.cjs"
        child.write_text(
            "process.send({execPath: process.execPath, ld: process.env.LD_LIBRARY_PATH || '', "
            "gconv: process.env.GCONV_PATH || '', locale: process.env.LOCALE_ARCHIVE || ''});\n",
            encoding="utf-8",
        )
        parent = self.temp / "symlink-parent.cjs"
        parent.write_text(
            "const cp = require('node:child_process');"
            "const child = cp.fork(process.argv[2], [], {stdio: ['ignore', 'ignore', 'pipe', 'ipc']});"
            "child.on('message', (m) => {"
            "  if (m.execPath !== process.env.EXPECTED_WRAPPER || m.ld !== '' || "
            "      m.gconv !== process.env.EXPECTED_GCONV || m.locale !== process.env.EXPECTED_LOCALE) "
            "    process.exitCode = 2;"
            "});"
            "child.on('exit', (code) => { if (code) process.exitCode = code; });\n",
            encoding="utf-8",
        )
        env = {
            **os.environ,
            "PATH": "/nonexistent",
            "TRACE": str(self.trace),
            "EXPECTED_WRAPPER": str(public_wrapper),
            "EXPECTED_GCONV": str(expected_gconv),
            "EXPECTED_LOCALE": str(expected_locale),
            "LD_LIBRARY_PATH": "/host/glibc",
            "GCONV_PATH": "/host/gconv",
            "LOCALE_ARCHIVE": "/host/locale-archive",
        }
        env.pop("SLIM_NODE_WRAPPER", None)
        result = subprocess.run(
            [str(public_wrapper), str(parent), str(child)],
            cwd=ROOT_DIR,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            trace[1],
            f"{runtime_root.resolve()}/lib:{(runtime_root / 'node' / 'dylib').resolve()}",
        )


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PortableNodeLauncherTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
PY
