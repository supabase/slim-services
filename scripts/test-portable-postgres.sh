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
COMPILER_RUNTIME = ROOT_DIR / "nix" / "portable-postgres" / "postgres-compiler-runtime.sh"
LINUX_FIXUP = ROOT_DIR / "nix" / "portable-postgres" / "postgres-linux-fixup.sh"


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
        self.real_locale_env = self.temp / "real.locale-env"
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
                "printf '%s\\n' \"${LANG-unset}\" \"${LANGUAGE-unset}\" \"${LC_ALL-unset}\" > \"$LOCALE_ENV\"\n"
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

    def run_launcher(self, public_name="postgres", args=(), root=None, stdin=None, extra_env=None):
        root = pathlib.Path(root or self.rootfs)
        launcher = root / "bin" / public_name
        env = {
            **os.environ,
            "PATH": "/nonexistent",
            "TRACE": str(self.trace),
            "ARGS_PATH": str(self.real_args[public_name]),
            "ENV_PATH": str(self.real_env[public_name]),
            "LOCALE_ENV": str(self.real_locale_env),
            "LD_LIBRARY_PATH": "/host/lib",
            "LD_PRELOAD": "/host/preload.so",
            "LD_AUDIT": "/host/audit.so",
            "GLIBC_TUNABLES": "glibc.malloc.check=3",
            "GCONV_PATH": "/host/gconv",
            "LOCALE_ARCHIVE": "/host/locale-archive",
            "LOCPATH": "/host/locale",
            "NSS_MODULE_PATH": "/host/nss",
        }
        if extra_env:
            env.update(extra_env)
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
        self.assertEqual(trace[0], f"argv0={self.rootfs.resolve() / 'bin' / 'postgres'}")
        self.assertEqual(trace[1], f"library-path={self.rootfs.resolve() / 'lib'}")
        self.assertEqual(trace[2], f"real={self.bin_dir.resolve() / '.postgres-portable-real'}")

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
        result = self.run_launcher(args=("--no-side-data",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.real_env["postgres"].read_text(encoding="utf-8").splitlines(),
            [
                "unset",
                "unset",
                "unset",
                "unset",
                "unset",
                str((self.lib_dir / "locale" / "locale-archive").resolve()),
                "unset",
                "unset",
                str(self.lib_dir.resolve()),
            ],
        )

    def test_launcher_requires_bundled_locale_archive(self):
        (self.lib_dir / "locale" / "locale-archive").unlink()
        result = self.run_launcher(args=("--version",))
        self.assertEqual(result.returncode, 127)
        self.assertIn("bundled locale archive is missing", result.stderr)

    def test_linux_fixup_requires_bundled_locale_archive(self):
        locale_source = self.temp / "locale-source"
        locale_source.mkdir()
        env = {
            **os.environ,
            "PORTABLE_POSTGRES_ROOTFS": str(self.rootfs),
            "PORTABLE_POSTGRES_GLIBC_LIB": str(self.lib_dir),
            "PORTABLE_POSTGRES_LOCALE_LIB": str(locale_source),
            "PORTABLE_POSTGRES_COMPILER_LIB": str(self.lib_dir),
            "PORTABLE_POSTGRES_COMPILER_LIBGCC": str(self.lib_dir),
            "PORTABLE_POSTGRES_COMPILER_SRC": str(self.temp / "compiler.tar"),
            "PORTABLE_POSTGRES_LAUNCHER": str(LAUNCHER),
            "PORTABLE_POSTGRES_ENTRYPOINT_HELPER": str(self.temp / "entrypoint.sh"),
            "PORTABLE_POSTGRES_COMPILER_HELPER": str(self.temp / "compiler.sh"),
        }
        result = subprocess.run(
            ["bash", str(LINUX_FIXUP)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundled locale archive is required", result.stderr)

    def test_launcher_pins_process_locale_to_bundled_en_us(self):
        result = self.run_launcher(
            args=("--version",),
            extra_env={
                "LANG": "C",
                "LANGUAGE": "C",
                "LC_ALL": "C",
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.real_locale_env.read_text(encoding="utf-8").splitlines(),
            ["en_US.UTF-8", "en_US:en", "en_US.UTF-8"],
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

    def test_compiler_runtime_selector_rejects_linker_scripts(self):
        compiler_root = self.temp / "compiler" / "lib"
        compiler_root.mkdir(parents=True)
        (compiler_root / "libstdc++.so.6").write_text("GNU ld script", encoding="utf-8")
        (compiler_root / "libstdc++.so.6.0.33").write_text("ELF fixture libstdc++", encoding="utf-8")
        (compiler_root / "libgcc_s.so.1.0.0").write_text("ELF fixture libgcc", encoding="utf-8")
        (compiler_root / "libgcc_s.so.1").symlink_to("libgcc_s.so.1.0.0")

        fakebin = self.temp / "runtime-fake-bin"
        fakebin.mkdir()
        (fakebin / "file").write_text(
            "#!/bin/sh\n"
            "if grep -q ELF \"$1\" 2>/dev/null; then echo \"$1: ELF executable\"; else echo \"$1: ASCII text\"; fi\n",
            encoding="utf-8",
        )
        (fakebin / "readelf").write_text(
            "#!/bin/sh\n"
            "echo '  Machine: Advanced Micro Devices X86-64'\n",
            encoding="utf-8",
        )
        for command in (fakebin / "file", fakebin / "readelf"):
            command.chmod(0o755)

        destination = self.temp / "runtime-out"
        env = {
            **os.environ,
            "PATH": f"{fakebin}:{os.environ['PATH']}",
            "PORTABLE_POSTGRES_COMPILER_RUNTIME_STANDALONE": "1",
            "PORTABLE_POSTGRES_RUNTIME_ARCH": "x86_64",
            "PORTABLE_POSTGRES_RUNTIME_DEST": str(destination),
            "PORTABLE_POSTGRES_RUNTIME_NAME": "libstdc++.so.6",
            "PORTABLE_POSTGRES_COMPILER_LIB": str(compiler_root),
            "PORTABLE_POSTGRES_COMPILER_LIBGCC": str(compiler_root),
        }
        result = subprocess.run([str(COMPILER_RUNTIME)], text=True, capture_output=True, env=env, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / "libstdc++.so.6").read_text(encoding="utf-8"), "ELF fixture libstdc++")

        env["PORTABLE_POSTGRES_RUNTIME_NAME"] = "libgcc_s.so.1"
        result = subprocess.run([str(COMPILER_RUNTIME)], text=True, capture_output=True, env=env, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / "libgcc_s.so.1").read_text(encoding="utf-8"), "ELF fixture libgcc")

        (compiler_root / "libstdc++.so.6.0.33").unlink()
        env["PORTABLE_POSTGRES_RUNTIME_NAME"] = "libstdc++.so.6"
        result = subprocess.run([str(COMPILER_RUNTIME)], text=True, capture_output=True, env=env, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no matching ELF libstdc++.so.6", result.stderr)

    def test_entrypoint_fixup_executable_seam_creates_public_launchers(self):
        rootfs = self.temp / "entrypoint-rootfs"
        (rootfs / "bin").mkdir(parents=True)
        (rootfs / "lib").mkdir(parents=True)
        (rootfs / "lib" / "locale").mkdir()
        (rootfs / "lib" / "locale" / "locale-archive").write_text("fixture", encoding="utf-8")
        (rootfs / "share").mkdir(parents=True)
        (rootfs / "share" / "sql_features.txt").write_text("fixture share data", encoding="utf-8")
        for name in ("postgres", "psql"):
            hidden = rootfs / "bin" / f".{name}-wrapped"
            hidden.write_text(
                "#!/bin/sh\n"
                "cd /\n"
                "share_dir=\"$(CDPATH= cd \"${0%/*}/../share\" && pwd -P)\"\n"
                "[ -f \"$share_dir/sql_features.txt\" ] || exit 73\n"
                "printf 'share=%s\\n' \"$share_dir\" >> \"$TRACE\"\n"
                "printf 'service=%s\\n' \"$0\" >> \"$TRACE\"\n"
                "printf 'arg=%s\\n' \"$1\" >> \"$TRACE\"\n",
                encoding="utf-8",
            )
            hidden.chmod(0o755)
        shared = rootfs / "lib" / "fixture.so"
        shared.write_text("fixture shared object", encoding="utf-8")
        shared.chmod(0o755)

        loader = rootfs / "lib" / "ld-linux-x86-64.so.2"
        loader.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "if [ \"${1:-}\" = --argv0 ]; then shift 2; fi\n"
            "[ \"${1:-}\" = --library-path ] || exit 41\n"
            "library_path=$2\n"
            "shift 2\n"
            "real=$1\n"
            "shift\n"
            "printf 'library-path=%s\\nreal=%s\\n' \"$library_path\" \"$real\" > \"$TRACE\"\n"
            "exec \"$real\" \"$@\"\n",
            encoding="utf-8",
        )
        loader.chmod(0o755)

        # Keep this host-only seam independent from a compiler or target ELF:
        # file/readelf are narrowly stubbed to model two executable ELFs and a
        # shared object with no PT_INTERP, then the real fixup script runs.
        fakebin = self.temp / "fake-bin"
        fakebin.mkdir()
        (fakebin / "file").write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  *.so|*.so.*) echo \"$1: ELF shared object\" ;;\n"
            "  *) echo \"$1: ELF executable\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        (fakebin / "readelf").write_text(
            "#!/bin/sh\n"
            "target=\"\"\n"
            "for arg do target=\"$arg\"; done\n"
            "case \"$target\" in\n"
            "  *.so|*.so.*) exit 1 ;;\n"
            "  *) echo ' INTERP 0x0' ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        for command in (fakebin / "file", fakebin / "readelf"):
            command.chmod(0o755)

        template = LAUNCHER
        trace = self.temp / "entrypoint-loader.trace"
        env = {
            **os.environ,
            "PATH": f"{fakebin}:{os.environ['PATH']}",
            "PORTABLE_POSTGRES_ENTRYPOINT_STANDALONE": "1",
            "PORTABLE_POSTGRES_ROOTFS": str(rootfs),
            "PORTABLE_POSTGRES_LAUNCHER": str(template),
            "PORTABLE_POSTGRES_LOADER_NAME": "ld-linux-x86-64.so.2",
            "PORTABLE_POSTGRES_ARGV0_SUPPORTED": "1",
            "TRACE": str(trace),
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
            self.assertIn(f"REAL_POSTGRES=\"$PG_BIN_DIR/.{name}-portable-real\"", public.read_text(encoding="utf-8"))
            relative_public = public.relative_to(self.temp)
            command = [str(relative_public)] if pathlib.Path("/usr/bin/sh").exists() else ["/bin/sh", str(relative_public)]
            result = subprocess.run(
                [*command, "--version"],
                text=True,
                capture_output=True,
                env=env,
                cwd=self.temp,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            trace_lines = trace.read_text(encoding="utf-8").splitlines()
            self.assertEqual(trace_lines[0], f"library-path={rootfs.resolve() / 'lib'}")
            self.assertEqual(trace_lines[1], f"real={rootfs.resolve() / 'bin' / f'.{name}-portable-real'}")
            self.assertEqual(trace_lines[2], f"share={rootfs.resolve() / 'share'}")
            self.assertEqual(trace_lines[3], f"service={rootfs.resolve() / 'bin' / f'.{name}-portable-real'}")
            self.assertEqual(trace_lines[4], "arg=--version")
        self.assertTrue(shared.is_file())
        self.assertFalse((rootfs / "lib" / ".fixture.so-portable-real").exists())

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
