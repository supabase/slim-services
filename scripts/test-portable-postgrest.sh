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
FIXUP = ROOT_DIR / "nix" / "portable-postgrest" / "postgrest-linux-fixup.sh"
LAUNCHER = ROOT_DIR / "nix" / "portable-postgrest" / "postgrest-launcher.sh"
IMAGE_BUILD = ROOT_DIR / "scripts" / "build-artifact-from-image.sh"
TRUE_BIN = pathlib.Path(shutil.which("true") or "/usr/bin/true")


class PortablePostgrestFixupTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-portable-postgrest."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.rootfs = self.temp / "rootfs"
        (self.rootfs / "bin").mkdir(parents=True)
        (self.rootfs / "lib").mkdir()
        (self.rootfs / "lib" / "x86_64-linux-gnu").mkdir()
        (self.rootfs / "lib" / "x86_64-linux-gnu" / "libc.so.6").write_text(
            "glibc fixture\n", encoding="utf-8"
        )
        (self.rootfs / "usr" / "lib" / "x86_64-linux-gnu" / "gconv").mkdir(parents=True)
        shutil.copyfile(TRUE_BIN, self.rootfs / "bin" / "postgrest")
        (self.rootfs / "bin" / "postgrest").chmod(0o755)
        self.fake_tools = self.temp / "fake-tools"
        self.fake_tools.mkdir()
        readelf = self.fake_tools / "readelf"
        readelf.write_text(
            "#!/bin/sh\n"
            "target=\"${2:-}\"\n"
            "grep -q STATIC \"$target\" 2>/dev/null && exit 0\n"
            "printf '%s\\n' '      [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]'\n",
            encoding="utf-8",
        )
        readelf.chmod(0o755)
        (self.rootfs / "usr" / "share" / "doc" / "libc6").mkdir(parents=True)
        (self.rootfs / "usr" / "share" / "doc" / "libc6" / "copyright").write_text(
            "glibc copyright fixture\n", encoding="utf-8"
        )
        self.trace = self.temp / "loader.trace"
        loader = self.rootfs / "lib" / "x86_64-linux-gnu" / "ld-linux-x86-64.so.2"
        loader.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "printf 'argv0=%s\\n' \"${2:-unset}\" > \"$TRACE\"\n"
            "if [ \"${1:-}\" = --argv0 ]; then shift 2; fi\n"
            "[ \"${1:-}\" = --library-path ] || exit 41\n"
            "printf 'library-path=%s\\n' \"$2\" >> \"$TRACE\"\n"
            "shift 2\n"
            "real=$1\n"
            "shift\n"
            "printf 'real=%s\\n' \"$real\" >> \"$TRACE\"\n"
            "printf 'ld=%s\\npreload=%s\\nside=%s\\n' \"${LD_LIBRARY_PATH-unset}\" \"${LD_PRELOAD-unset}\" \"${GCONV_PATH-unset}\" >> \"$TRACE\"\n"
            "exec \"$real\" \"$@\"\n",
            encoding="utf-8",
        )
        loader.chmod(0o755)

    def run_wrapper(self, root=None):
        root = pathlib.Path(root or self.rootfs)
        env = {
            **os.environ,
            "PATH": f"{self.fake_tools}:{os.environ['PATH']}",
            "TRACE": str(self.trace),
            "LD_LIBRARY_PATH": "/host/glibc",
            "LD_PRELOAD": "/host/preload.so",
            "GCONV_PATH": "/host/gconv",
            "LOCALE_ARCHIVE": "/host/locale-archive",
        }
        wrapper = root / "bin" / "postgrest"
        # Execute the generated file directly so its /bin/sh shebang is part
        # of the host portability contract; never mask a missing image shell
        # by selecting another host path.
        command = [str(wrapper)]
        return subprocess.run(
            [*command, "--example"],
            cwd=ROOT_DIR,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_dynamic_fixup_generates_relocatable_public_launcher(self):
        result = subprocess.run(
            ["bash", str(FIXUP), str(self.rootfs)],
            cwd=ROOT_DIR,
            env={**os.environ, "PATH": f"{self.fake_tools}:{os.environ['PATH']}"},
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        wrapper = self.rootfs / "bin" / "postgrest"
        real = self.rootfs / "bin" / ".postgrest-portable-real"
        self.assertTrue(wrapper.is_file())
        self.assertTrue(real.is_file())
        self.assertEqual(real.read_bytes(), TRUE_BIN.read_bytes())
        self.assertEqual(
            (self.rootfs / "share" / "licenses" / "portable-postgrest" / "glibc6-copyright").read_text(
                encoding="utf-8"
            ),
            "glibc copyright fixture\n",
        )

        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8").splitlines()
        self.assertEqual(trace[0], f"argv0={self.rootfs / 'bin' / 'postgrest'}")
        self.assertIn(str(self.rootfs.resolve() / "lib"), trace[1])
        self.assertIn(str(self.rootfs.resolve() / "usr" / "lib" / "x86_64-linux-gnu"), trace[1])
        self.assertEqual(trace[2], f"real={real}")
        self.assertEqual(trace[3:], ["ld=unset", "preload=unset", f"side={(self.rootfs / 'usr' / 'lib' / 'x86_64-linux-gnu' / 'gconv').resolve()}"])

        relocated = self.temp / "relocated root"
        shutil.copytree(self.rootfs, relocated)
        result = self.run_wrapper(relocated)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(relocated.resolve() / "lib"), self.trace.read_text(encoding="utf-8"))

    def test_static_or_non_elf_release_is_left_direct(self):
        binary = self.rootfs / "bin" / "postgrest"
        binary.write_text("#!/bin/sh\n# STATIC\nprintf static\\n", encoding="utf-8")
        binary.chmod(0o755)
        before = binary.read_bytes()
        result = subprocess.run(
            ["bash", str(FIXUP), str(self.rootfs)],
            cwd=ROOT_DIR,
            env={**os.environ, "PATH": f"{self.fake_tools}:{os.environ['PATH']}"},
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(binary.read_bytes(), before)
        self.assertFalse((self.rootfs / "bin" / ".postgrest-portable-real").exists())

    def test_recipe_carries_nss_modules_for_both_linux_multiarch_layouts(self):
        recipe = (ROOT_DIR / "services" / "postgrest" / "recipe.env").read_text(
            encoding="utf-8"
        )
        for prefix in ("aarch64-linux-gnu", "x86_64-linux-gnu"):
            for base in ("/lib", "/usr/lib"):
                for module in ("libnss_dns.so.2", "libnss_files.so.2"):
                    self.assertIn(f'"{base}/{prefix}/{module}"', recipe)

    def test_image_builder_invokes_real_postprocess_hook(self):
        fixture_bin = TRUE_BIN
        fake_docker = self.temp / "fake-docker"
        fake_docker.mkdir()
        docker = fake_docker / "docker"
        docker.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, shutil, sys\n"
            "args = sys.argv[1:]\n"
            "if args and args[0] == 'create':\n"
            "    print('fixture-container')\n"
            "    raise SystemExit(0)\n"
            "if args and args[0] == 'rm':\n"
            "    raise SystemExit(0)\n"
            "if args and args[0] == 'cp':\n"
            "    source = args[1]\n"
            "    if source == 'fixture-container:/usr/share/doc/libc6/copyright':\n"
            "        destination = pathlib.Path(args[2]); destination.mkdir(parents=True, exist_ok=True)\n"
            "        shutil.copyfile(os.environ['FIXTURE_LICENSE'], destination / 'copyright')\n"
            "        raise SystemExit(0)\n"
            "    if source != 'fixture-container:/bin/postgrest': raise SystemExit(1)\n"
            "    destination = pathlib.Path(args[2])\n"
            "    destination.mkdir(parents=True, exist_ok=True)\n"
            "    shutil.copyfile(os.environ['FIXTURE_BINARY'], destination / 'postgrest')\n"
            "    (destination / 'postgrest').chmod(0o755)\n"
            "    raise SystemExit(0)\n"
            "if args and args[0] == 'run':\n"
            "    mount = args[args.index('-v') + 1]\n"
            "    rootfs = pathlib.Path(mount.split(':', 1)[0])\n"
            "    loader = rootfs / 'lib' / 'x86_64-linux-gnu' / 'ld-linux-x86-64.so.2'\n"
            "    loader.parent.mkdir(parents=True, exist_ok=True)\n"
            "    shutil.copyfile(os.environ['FIXTURE_LOADER'], loader)\n"
            "    loader.chmod(0o755)\n"
            "    raise SystemExit(0)\n"
            "raise SystemExit(1)\n",
            encoding="utf-8",
        )
        docker.chmod(0o755)
        version = f"postprocess-{os.getpid()}"
        artifact = ROOT_DIR / "artifacts" / "postgrest" / version
        self.addCleanup(shutil.rmtree, artifact)
        env = {
            **os.environ,
            "PATH": f"{fake_docker}:{self.fake_tools}:{os.environ['PATH']}",
            "SOURCE_IMAGE": "fixture-image",
            "ARTIFACT_ARCHIVE_ON_BUILD": "0",
            "TARGET_OS": "linux",
            "ARCH": "amd64",
            "VERSION": version,
            "FIXTURE_BINARY": str(fixture_bin),
            "FIXTURE_LOADER": str(self.rootfs / "lib" / "x86_64-linux-gnu" / "ld-linux-x86-64.so.2"),
            "FIXTURE_LICENSE": str(self.rootfs / "usr" / "share" / "doc" / "libc6" / "copyright"),
        }
        result = subprocess.run(
            ["bash", str(IMAGE_BUILD), "postgrest", version],
            cwd=ROOT_DIR,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        built_rootfs = artifact / "linux-amd64" / "rootfs"
        self.assertTrue((built_rootfs / "bin" / "postgrest").is_file())
        self.assertTrue((built_rootfs / "bin" / ".postgrest-portable-real").is_file())
        self.assertEqual(
            (built_rootfs / "share" / "licenses" / "portable-postgrest" / "glibc6-copyright").read_text(
                encoding="utf-8"
            ),
            "glibc copyright fixture\n",
        )
        self.assertIn("running artifact postprocess script", result.stdout)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PortablePostgrestFixupTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
PY
