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
LAUNCHER = ROOT_DIR / "nix" / "portable-postgres" / "postgres-launcher.sh"
ENTRYPOINT_FIXUP = ROOT_DIR / "nix" / "portable-postgres" / "postgres-entrypoint-fixup.sh"
PACKAGE = ROOT_DIR / "services" / "postgres" / "nix" / "packages" / "postgres-portable.nix"


class PortablePostgresLauncherTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not LAUNCHER.is_file():
            raise RuntimeError(
                "portable-postgres launcher seam is absent; baseline still exposes host-loader PostgreSQL ELFs"
            )

    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-portable-postgres."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.rootfs = self.temp / "rootfs"
        self.bin_dir = self.rootfs / "bin"
        self.bin_dir.mkdir(parents=True)
        self.lib_dir = self.rootfs / "lib"
        (self.lib_dir / "gconv").mkdir(parents=True)
        (self.lib_dir / "locale").mkdir()
        (self.lib_dir / "locale" / "locale-archive").write_text("fixture", encoding="utf-8")
        self.trace = self.temp / "loader.trace"
        self.real_args = {}
        self.real_env = {}
        self.real_paths = {}

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
            "printf 'argv0=%s\\nlibrary-path=%s\\nreal=%s\\n' \"$argv0\" \"$library_path\" \"$real\" > \"$TRACE\"\n"
            "exec \"$real\" \"$@\"\n",
            encoding="utf-8",
        )
        loader.chmod(0o755)

        template = LAUNCHER.read_text(encoding="utf-8")
        for public_name in ("postgres", "initdb", "pg_ctl"):
            public = self.bin_dir / public_name
            real = self.bin_dir / f".{public_name}-portable-real"
            args_path = self.temp / f"{public_name}.args"
            env_path = self.temp / f"{public_name}.env"
            real.write_text(
                "#!/bin/sh\n"
                "set -eu\n"
                ": > \"$ARGS_PATH\"\n"
                "printf '%s\\n' \"$@\" >> \"$ARGS_PATH\"\n"
                "printf '%s\\n' \"${LD_LIBRARY_PATH-unset}\" \"${LD_PRELOAD-unset}\" \"${LD_AUDIT-unset}\" \"${GLIBC_TUNABLES-unset}\" \"${GCONV_PATH-unset}\" \"${LOCALE_ARCHIVE-unset}\" \"${LOCPATH-unset}\" \"${NSS_MODULE_PATH-unset}\" > \"$ENV_PATH\"\n"
                "printf '%s\\n' \"${NIX_PGLIBDIR-unset}\" >> \"$ENV_PATH\"\n",
                encoding="utf-8",
            )
            real.chmod(0o755)
            generated = (
                template.replace("@LOADER_NAME@", loader.name)
                .replace("@ROOT_REL@", "..")
                .replace("@REAL_NAME@", real.name)
                .replace("@ARGV0_SUPPORTED@", "1")
            )
            public.write_text(generated, encoding="utf-8")
            public.chmod(0o755)
            self.real_args[public_name] = args_path
            self.real_env[public_name] = env_path

    def run_launcher(self, public_name="postgres", args=(), root=None, stdin=None):
        root = pathlib.Path(root or self.rootfs)
        launcher = root / "bin" / public_name
        env = {
            **os.environ,
            "PATH": "/nonexistent",
            "TRACE": str(self.trace),
            "ARGS_PATH": str(self.real_args[public_name]),
            "ENV_PATH": str(self.real_env[public_name]),
            "LD_LIBRARY_PATH": "/host/lib",
            "LD_PRELOAD": "/host/preload.so",
            "LD_AUDIT": "/host/audit.so",
            "GLIBC_TUNABLES": "glibc.malloc.check=3",
            "GCONV_PATH": "/host/gconv",
            "LOCALE_ARCHIVE": "/host/locale-archive",
            "LOCPATH": "/host/locale",
            "NSS_MODULE_PATH": "/host/nss",
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

    def test_loader_and_library_path_follow_relocated_artifact(self):
        result = self.run_launcher(args=("--version",))
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8").splitlines()
        self.assertEqual(trace[0], f"argv0={self.rootfs / 'bin' / 'postgres'}")
        self.assertEqual(trace[1], f"library-path={self.rootfs.resolve() / 'lib'}")
        self.assertEqual(trace[2], f"real={self.bin_dir / '.postgres-portable-real'}")

        relocated = self.temp / "relocated root"
        shutil.copytree(self.rootfs, relocated)
        result = self.run_launcher(root=relocated, args=("--relocated",))
        self.assertEqual(result.returncode, 0, result.stderr)
        relocated_trace = self.trace.read_text(encoding="utf-8")
        self.assertIn(f"library-path={relocated.resolve() / 'lib'}", relocated_trace)

    def test_launcher_clears_poisoned_environment_and_sets_artifact_side_data(self):
        result = self.run_launcher(args=("-D", "/tmp/data"))
        self.assertEqual(result.returncode, 0, result.stderr)
        values = self.real_env["postgres"].read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            values,
            [
                "unset",
                "unset",
                "unset",
                "unset",
                str((self.lib_dir / "gconv").resolve()),
                str((self.lib_dir / "locale" / "locale-archive").resolve()),
                "unset",
                "unset",
                str(self.lib_dir.resolve()),
            ],
        )

        shutil.rmtree(self.lib_dir / "gconv")
        (self.lib_dir / "locale" / "locale-archive").unlink()
        result = self.run_launcher(args=("--no-side-data",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.real_env["postgres"].read_text(encoding="utf-8").splitlines(),
            ["unset", "unset", "unset", "unset", "unset", "unset", "unset", "unset", str(self.lib_dir.resolve())],
        )

    def test_multiple_public_entrypoints_use_the_same_template(self):
        for name in ("postgres", "initdb", "pg_ctl"):
            with self.subTest(name=name):
                result = self.run_launcher(name, args=("--version",))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    self.real_args[name].read_text(encoding="utf-8").splitlines(),
                    ["--version"],
                )

    def test_missing_loader_and_real_binary_fail_loudly(self):
        loader = self.lib_dir / "ld-linux-x86-64.so.2"
        loader.unlink()
        result = self.run_launcher()
        self.assertEqual(result.returncode, 127)
        self.assertIn("bundled loader is missing", result.stderr)

        loader.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        loader.chmod(0o755)
        (self.bin_dir / ".postgres-portable-real").unlink()
        result = self.run_launcher()
        self.assertEqual(result.returncode, 127)
        self.assertIn("real PostgreSQL executable is missing", result.stderr)

    def test_generated_launcher_uses_image_sh_path_and_not_bash_helpers(self):
        content = LAUNCHER.read_text(encoding="utf-8")
        self.assertEqual(content.splitlines()[0], "#!/usr/bin/sh")
        self.assertNotIn("BASH_SOURCE", content)
        self.assertNotIn("dirname", content)
        self.assertNotIn("uname", content)

    def test_package_keeps_shared_objects_unwrapped_and_bundles_glibc(self):
        content = PACKAGE.read_text(encoding="utf-8")
        fixup = (ROOT_DIR / "nix" / "portable-postgres" / "postgres-linux-fixup.sh").read_text(encoding="utf-8")
        self.assertIn("glibcLocales", content)
        self.assertIn("ld-linux-aarch64.so.1", fixup)
        self.assertIn("libc.so.6", fixup)
        self.assertIn("postgres-launcher.sh", content)
        self.assertIn("PT_INTERP", fixup)
        self.assertNotIn("for so in $out/lib/*.so*; do", content)

    def test_linux_fixup_normalizes_hidden_nix_entrypoints_before_wrapping(self):
        fixup = (ROOT_DIR / "nix" / "portable-postgres" / "postgres-entrypoint-fixup.sh").read_text(encoding="utf-8")
        self.assertIn('for hidden in "$rootfs"/bin/.*-wrapped; do', fixup)
        self.assertIn('public_name="${public_name#.}"', fixup)
        self.assertIn('public_name="${public_name%-wrapped}"', fixup)
        self.assertIn('mv "$hidden" "$public_path"', fixup)
        for expected in ("postgres", "pg_config", "pg_ctl", "initdb", "psql", "pg_dump", "pg_dumpall", "pg_restore", "createdb", "dropdb", "pg_isready"):
            self.assertIn(expected, PACKAGE.read_text(encoding="utf-8"))

    def test_entrypoint_fixup_executable_seam_creates_public_launchers(self):
        rootfs = self.temp / "entrypoint-rootfs"
        (rootfs / "bin").mkdir(parents=True)
        for name in ("postgres", "psql"):
            hidden = rootfs / "bin" / f".{name}-wrapped"
            hidden.write_text("fixture ELF", encoding="utf-8")
            hidden.chmod(0o755)
        shared = rootfs / "lib" / "fixture.so"
        shared.parent.mkdir(parents=True)
        shared.write_text("fixture shared object", encoding="utf-8")
        shared.chmod(0o755)

        # Keep this host-only seam independent from a compiler or target ELF:
        # file/readelf are narrowly stubbed to model two executable ELFs and a
        # shared object with no PT_INTERP, then the real fixup script runs.
        fakebin = self.temp / "fake-bin"
        fakebin.mkdir()
        (fakebin / "file").write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  *.so) echo \"$1: ELF shared object\" ;;\n"
            "  *) echo \"$1: ELF executable\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        (fakebin / "readelf").write_text(
            "#!/bin/sh\n"
            "target=\"\"\n"
            "for arg do target=\"$arg\"; done\n"
            "case \"$target\" in\n"
            "  *.so) exit 1 ;;\n"
            "  *) echo ' INTERP 0x0' ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        for command in (fakebin / "file", fakebin / "readelf"):
            command.chmod(0o755)

        template = self.temp / "entrypoint-template.sh"
        template.write_text(
            "#!/usr/bin/sh\n"
            "# loader=@LOADER_NAME@ root=@ROOT_REL@ real=@REAL_NAME@ argv0=@ARGV0_SUPPORTED@\n",
            encoding="utf-8",
        )
        env = {
            **os.environ,
            "PATH": f"{fakebin}:{os.environ['PATH']}",
            "PORTABLE_POSTGRES_ENTRYPOINT_STANDALONE": "1",
            "PORTABLE_POSTGRES_ROOTFS": str(rootfs),
            "PORTABLE_POSTGRES_LAUNCHER": str(template),
            "PORTABLE_POSTGRES_LOADER_NAME": "ld-linux-x86-64.so.2",
            "PORTABLE_POSTGRES_ARGV0_SUPPORTED": "1",
        }
        result = subprocess.run(
            [str(ENTRYPOINT_FIXUP)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("postgres", "psql"):
            public = rootfs / "bin" / name
            self.assertTrue(public.is_file(), name)
            self.assertTrue(public.stat().st_mode & 0o111, name)
            self.assertTrue((rootfs / "bin" / f".{name}-portable-real").is_file(), name)
            self.assertFalse((rootfs / "bin" / f".{name}-wrapped").exists(), name)
            self.assertIn(f"real=.{name}-portable-real", public.read_text(encoding="utf-8"))
        self.assertTrue(shared.is_file())
        self.assertFalse((rootfs / "lib" / ".fixture.so-portable-real").exists())

    def test_linux_fixup_assets_are_present_in_both_build_runners(self):
        recipe = (ROOT_DIR / "services" / "postgres" / "recipe.env").read_text(encoding="utf-8")
        dockerfile = (ROOT_DIR / "services" / "postgres" / "Dockerfile.artifact").read_text(encoding="utf-8")
        self.assertIn('"nix/portable-postgres:nix/portable-postgres"', recipe)
        self.assertIn("COPY nix/portable-postgres/ nix/portable-postgres/", dockerfile)

    def test_license_tar_listing_does_not_sigpipe_under_pipefail(self):
        archive_root = self.temp / "source"
        (archive_root / "gcc").mkdir(parents=True)
        (archive_root / "gcc" / "COPYING.RUNTIME").write_text("runtime", encoding="utf-8")
        (archive_root / "gcc" / "COPYING3").write_text("gpl", encoding="utf-8")
        archive = self.temp / "gcc.tar"
        subprocess.run(
            ["tar", "-cf", str(archive), "-C", str(archive_root), "gcc"],
            check=True,
        )
        command = (
            "set -o pipefail; "
            "tar -tf \"$1\" | awk -v suffix=\"/COPYING.RUNTIME\" "
            "'length($0) >= length(suffix) && substr($0, length($0) - length(suffix) + 1) == suffix && first == \"\" { first = $0 } "
            "END { if (first != \"\") print first }'"
        )
        result = subprocess.run(
            ["bash", "-c", command, "test", str(archive)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "gcc/COPYING.RUNTIME")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PortablePostgresLauncherTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
PY
