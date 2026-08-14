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
AUDIT = ROOT_DIR / "scripts" / "audit-portable-artifact.sh"


class PortableAuditTest(unittest.TestCase):
    def setUp(self):
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="slim-portable-audit."))
        self.addCleanup(shutil.rmtree, self.temp)
        self.rootfs = self.temp / "rootfs"
        (self.rootfs / "bin").mkdir(parents=True)
        (self.rootfs / "lib64").mkdir()
        self.fake_bin = self.temp / "bin"
        self.fake_bin.mkdir()
        self.trace = self.temp / "trace"
        self.write_tools()

    def write_tools(self):
        # The fixture is deliberately classified as ELF while the controlled
        # file/readelf/os-floor tools provide the narrow audit surface.
        (self.fake_bin / "file").write_text(
            "#!/usr/bin/env bash\n"
            "file_target=\"$1\"\n"
            "if [[ $1 == -b ]]; then file_target=\"$3\"; fi\n"
            "if [[ $(basename \"$file_target\") == static ]]; then\n"
            "  if [[ $1 == -b ]]; then printf 'ELF 64-bit LSB statically linked\\n'; else printf '%s: ELF 64-bit LSB statically linked\\n' \"$file_target\"; fi\n"
            "else\n"
            "  if [[ $1 == -b ]]; then printf 'ELF 64-bit LSB pie executable\\n'; else printf '%s: ELF 64-bit LSB pie executable\\n' \"$file_target\"; fi\n"
            "fi\n",
            encoding="utf-8",
        )
        (self.fake_bin / "readelf").write_text(
            "#!/usr/bin/env bash\n"
            "case $1 in\n"
            "  -d) exit 0 ;;\n"
            "  -l) printf '%s\\n' '      [Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]' ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        (self.fake_bin / "ldd").write_text(
            "#!/usr/bin/env bash\nprintf 'ldd %s\\n' \"$1\" >> \"$FAKE_TRACE\"\n"
            "if [[ $1 == *app || $1 == *static || $1 == *dynamic* ]]; then exit 1; fi\n"
            "if [[ $1 == *unresolved ]]; then printf '\\tlibmissing.so => not found\\n'; fi\n"
            "printf '\\tlibfixture.so => /artifact/libfixture.so (0x0)\\n'\n",
            encoding="utf-8",
        )
        (self.fake_bin / "os-floor.sh").write_text(
            "#!/usr/bin/env bash\nprintf '{\"floor\": null, \"bundled_glibc\": false}\\n'\n",
            encoding="utf-8",
        )
        (self.fake_bin / "uname").write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${1:-} == -m ]]; then printf '%s\\n' x86_64; else /usr/bin/uname \"$@\"; fi\n",
            encoding="utf-8",
        )
        for path in self.fake_bin.iterdir():
            path.chmod(0o755)

    def env(self, loader_mode="ok"):
        loader = self.rootfs / "lib64" / "ld-linux-x86-64.so.2"
        loader.write_text(
            "#!/usr/bin/env bash\n"
            "printf 'loader %s\\n' \"$*\" >> \"$FAKE_TRACE\"\n"
            + ("exit 7\n" if loader_mode == "fail" else "printf 'libfixture.so => /rootfs/libfixture.so (0x0)\\n'\n"),
            encoding="utf-8",
        )
        loader.chmod(0o755)
        return {
            **os.environ,
            "PATH": f"{self.fake_bin}:{os.environ['PATH']}",
            "FAKE_TRACE": str(self.trace),
            "ROOT_DIR": str(ROOT_DIR),
        }

    def run_audit(self, loader_mode="ok", bundled=True):
        loader = self.rootfs / "lib64" / "ld-linux-x86-64.so.2"
        if bundled:
            result_env = self.env(loader_mode)
        else:
            loader.unlink(missing_ok=True)
            result_env = self.env(loader_mode)
            loader.unlink(missing_ok=True)
        return subprocess.run(
            ["bash", str(AUDIT), "--linux", str(self.rootfs)],
            cwd=ROOT_DIR,
            env=result_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_bundled_loader_is_used_with_library_path_and_list(self):
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        (self.fake_bin / "ldd").unlink()
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8")
        self.assertNotIn("ldd", trace)
        self.assertIn("--library-path", trace)
        self.assertIn("--list", trace)

    def test_bundled_loader_failure_is_loud(self):
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        result = self.run_audit("fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundled loader audit failed", result.stderr)

    def test_static_elf_ldd_failure_is_tolerated(self):
        (self.rootfs / "bin" / "static").write_text("fixture", encoding="utf-8")
        result = self.run_audit(bundled=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ldd", self.trace.read_text(encoding="utf-8"))

    def test_dynamic_elf_ldd_failure_is_loud(self):
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        result = self.run_audit(bundled=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ldd audit failed", result.stderr)

    def test_dynamic_elf_unresolved_dependency_is_reported(self):
        (self.rootfs / "bin" / "unresolved").write_text("fixture", encoding="utf-8")
        result = self.run_audit(bundled=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not found", result.stderr)

    def test_dynamic_filename_cannot_claim_static_classification(self):
        for name in (
            "dynamic: statically linked",
            "dynamic: static-pie",
        ):
            (self.rootfs / "bin" / name).write_text("fixture", encoding="utf-8")
        result = self.run_audit(bundled=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ldd audit failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
PY

echo "portable audit tests passed"
