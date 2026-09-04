#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


sys.dont_write_bytecode = True
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
        self.audit_root = self.temp / "scripts"
        self.audit_root.mkdir()
        shutil.copy2(AUDIT, self.audit_root / "audit-portable-artifact.sh")
        shutil.copy2(ROOT_DIR / "scripts" / "lib.sh", self.audit_root / "lib.sh")
        shutil.copy2(
            ROOT_DIR / "scripts" / "validate-artifact-symlinks.py",
            self.audit_root / "validate-artifact-symlinks.py",
        )
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
        (self.audit_root / "os-floor.sh").write_text(
            "#!/usr/bin/env bash\n"
            "if [[ -n \"${FAKE_FLOOR_JSON:-}\" ]]; then\n"
            "  printf '%s\\n' \"$FAKE_FLOOR_JSON\"\n"
            "else\n"
            "  printf '{\\\"floor\\\": null, \\\"bundled_glibc\\\": false}\\n'\n"
            "fi\n",
            encoding="utf-8",
        )
        (self.audit_root / "os-floor.sh").chmod(0o755)
        (self.fake_bin / "uname").write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${1:-} == -m ]]; then printf '%s\\n' x86_64; else /usr/bin/uname \"$@\"; fi\n",
            encoding="utf-8",
        )
        for path in self.fake_bin.iterdir():
            path.chmod(0o755)

    def loader_path(self, loader_layout="canonical"):
        if loader_layout == "multiarch":
            return self.rootfs / "lib" / "x86_64-linux-gnu" / "ld-linux-x86-64.so.2"
        return self.rootfs / "lib64" / "ld-linux-x86-64.so.2"

    def env(self, loader_mode="ok", loader_layout="canonical", paired_libc=True):
        loader = self.loader_path(loader_layout)
        loader.parent.mkdir(parents=True, exist_ok=True)
        if loader_layout == "canonical" and paired_libc:
            (self.rootfs / "lib64" / "libc.so.6").write_text("fixture", encoding="utf-8")
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

    def run_audit(
        self,
        loader_mode="ok",
        bundled=True,
        floor_json=None,
        loader_layout="canonical",
        paired_libc=True,
    ):
        loader = self.loader_path(loader_layout)
        if bundled:
            result_env = self.env(loader_mode, loader_layout, paired_libc)
        else:
            loader.unlink(missing_ok=True)
            result_env = self.env(loader_mode, loader_layout, paired_libc)
            loader.unlink(missing_ok=True)
        if floor_json is not None:
            result_env["FAKE_FLOOR_JSON"] = floor_json
        return subprocess.run(
            ["bash", str(self.audit_root / "audit-portable-artifact.sh"), "--linux", str(self.rootfs)],
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

    def test_host_glibc_floor_defaults_to_235(self):
        (self.rootfs / "bin" / "host").write_text("fixture", encoding="utf-8")
        result = self.run_audit(
            bundled=False,
            floor_json='{"floor":"2.39","bundled_glibc":false}',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("policy 2.35", result.stderr)

    def test_bundled_floor_bypass_requires_loader_resolution(self):
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        result = self.run_audit(
            loader_mode="fail",
            floor_json='{"floor":"2.39","bundled_glibc":true}',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundled loader audit failed", result.stderr)

    def test_bundled_floor_bypass_requires_executable_loader(self):
        (self.rootfs / "bin" / "host").write_text("fixture", encoding="utf-8")
        result = self.run_audit(
            bundled=False,
            floor_json='{"floor":"2.39","bundled_glibc":true}',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no executable bundled loader", result.stderr)

    def test_resolved_bundled_loader_is_classified_as_hermetic(self):
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        result = self.run_audit(
            floor_json='{"floor":"2.39","bundled_glibc":true}',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("glibc floor gate skipped", result.stdout)

    def test_multiarch_bundled_loader_is_used_with_paired_libc(self):
        multiarch = self.rootfs / "lib" / "x86_64-linux-gnu"
        multiarch.mkdir(parents=True)
        (multiarch / "libc.so.6").write_text("fixture", encoding="utf-8")
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        (self.fake_bin / "ldd").unlink()
        result = self.run_audit(loader_layout="multiarch")
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text(encoding="utf-8")
        self.assertNotIn("ldd", trace)
        self.assertIn("--library-path", trace)
        self.assertIn(str(multiarch), trace)
        self.assertIn("--list", trace)

    def test_multiarch_loader_requires_paired_libc(self):
        multiarch = self.rootfs / "lib" / "x86_64-linux-gnu"
        multiarch.mkdir(parents=True)
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        result = self.run_audit(loader_layout="multiarch")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no paired libc", result.stderr)

    def test_canonical_loader_requires_paired_libc(self):
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        result = self.run_audit(paired_libc=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("canonical bundled loader has no paired libc", result.stderr)

    def test_equivalent_canonical_loader_symlink_is_not_ambiguous(self):
        canonical_alias = self.rootfs / "lib" / "ld-linux-x86-64.so.2"
        canonical_alias.parent.mkdir(parents=True)
        canonical_alias.symlink_to("../lib64/ld-linux-x86-64.so.2")
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        (self.fake_bin / "ldd").unlink()
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_multiarch_loader_cannot_coexist_with_canonical_loader(self):
        self.env()
        multiarch = self.rootfs / "lib" / "x86_64-linux-gnu"
        multiarch.mkdir(parents=True)
        (multiarch / "libc.so.6").write_text("fixture", encoding="utf-8")
        multiarch_loader = self.loader_path("multiarch")
        multiarch_loader.write_text("fixture", encoding="utf-8")
        multiarch_loader.chmod(0o755)
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        result = self.run_audit(loader_layout="multiarch")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous canonical and multiarch", result.stderr)

    def test_mismatched_multiarch_loader_is_rejected(self):
        wrong = self.rootfs / "lib" / "aarch64-linux-gnu" / "ld-linux-aarch64.so.1"
        wrong.parent.mkdir(parents=True)
        wrong.write_text("fixture", encoding="utf-8")
        wrong.chmod(0o755)
        (self.rootfs / "bin" / "app").write_text("fixture", encoding="utf-8")
        result = self.run_audit(bundled=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mismatched multiarch", result.stderr)

    def test_dangling_symlink_is_rejected(self):
        (self.rootfs / "bin" / "broken").symlink_to("missing")
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dangling symlink", result.stderr)

    def test_symlink_resolving_outside_root_is_rejected(self):
        (self.temp / "outside").write_text("outside", encoding="utf-8")
        (self.rootfs / "bin" / "escape").symlink_to("../../outside")
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside artifact root", result.stderr)

    def test_absolute_symlink_is_rejected(self):
        (self.rootfs / "bin" / "absolute").symlink_to("/etc/passwd")
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absolute symlink", result.stderr)

    def test_symlink_with_non_directory_trailing_slash_is_rejected(self):
        (self.rootfs / "bin" / "regular").write_text("fixture", encoding="utf-8")
        (self.rootfs / "bin" / "malformed").symlink_to("regular/")
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot resolve", result.stderr)

    def test_symlink_with_non_directory_component_is_rejected(self):
        (self.rootfs / "bin" / "regular").write_text("fixture", encoding="utf-8")
        for index, target in enumerate(("regular/.", "regular/..", "regular/../other", "regular//.")):
            (self.rootfs / "bin" / f"malformed-{index}").symlink_to(target)
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        for index in range(4):
            self.assertIn(f"malformed-{index}", result.stderr)
        self.assertIn("cannot resolve", result.stderr)

    def test_empty_symlink_target_is_rejected(self):
        empty = self.rootfs / "bin" / "empty"
        try:
            os.symlink("", empty)
        except (OSError, ValueError) as error:
            self.skipTest(f"platform refuses empty symlink target: {error}")
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty symlink target", result.stderr)

    def test_symlink_cycle_is_rejected(self):
        (self.rootfs / "bin" / "cycle-a").symlink_to("cycle-b")
        (self.rootfs / "bin" / "cycle-b").symlink_to("cycle-a")
        result = self.run_audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot resolve", result.stderr)

    def test_tree_scan_errors_are_reported(self):
        module_path = ROOT_DIR / "scripts" / "validate-artifact-symlinks.py"
        spec = __import__("importlib.util").util.spec_from_file_location(
            "validate_artifact_symlinks", module_path
        )
        module = __import__("importlib.util").util.module_from_spec(spec)
        spec.loader.exec_module(module)

        def failing_walk(root, topdown=True, followlinks=False, onerror=None):
            if onerror is None:
                raise AssertionError("validator did not install a scan error handler")
            onerror(OSError("fixture scan failure"))
            return []

        with mock.patch.object(module.os, "walk", failing_walk):
            failures = module.validate(self.rootfs)
        self.assertEqual(len(failures), 1)
        self.assertIn("cannot scan directory", failures[0])


if __name__ == "__main__":
    unittest.main()
PY

echo "portable audit tests passed"
