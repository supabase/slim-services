#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import os
import json
import io
import pathlib
import shutil
import subprocess
import tarfile
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

    def test_local_auxiliary_overlay_stages_shared_seam_before_nix_build(self):
        """Exercise build-artifact-from-nix's real local export path."""
        fixture_root = self.temp / "local-export-repo"
        (fixture_root / "scripts").mkdir(parents=True)
        for name in (
            "build-artifact-from-nix.sh",
            "lib.sh",
            "prune-runtime-tree.sh",
            "generate-artifact-sbom.sh",
            "generate-artifact-sbom.py",
            "measure-artifact.sh",
        ):
            shutil.copy2(ROOT_DIR / "scripts" / name, fixture_root / "scripts" / name)
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(ROOT_DIR / name, fixture_root / name)
        shutil.copytree(ROOT_DIR / "nix" / "portable-beam", fixture_root / "nix" / "portable-beam")

        service_dir = fixture_root / "services" / "realtime"
        service_dir.mkdir(parents=True)
        (service_dir / "recipe.env").write_text(
            'SOURCE_DIR="sources/realtime"\n'
            'SOURCE_REF="${SOURCE_REF:-fixture}"\n'
            'ARTIFACT_BACKEND="nix"\n'
            'BASE_IMAGE="scratch"\n'
            "ENTRYPOINT_JSON='[]'\n"
            "CMD_JSON='[]'\n"
            'NIX_FLAKE="."\n'
            'NIX_ATTR="fixture"\n'
            'NIX_BUILD_MODE="nix-build"\n'
            'NIX_EXPRESSION="."\n'
            'NIX_RUNNER="${NIX_RUNNER:-auto}"\n'
            'NIX_OUTPUT_KIND="rootfs"\n'
            "NIX_COPY_PATHS_JSON='[]'\n"
            'NIX_PACKAGE_OVERLAY=""\n'
            'NIX_PACKAGE_OVERLAY_DEST=""\n'
            'NIX_AUXILIARY_OVERLAYS=(\n'
            '  "nix/portable-beam:nix/portable-beam"\n'
            ')\n'
            'PORTABLE="true"\n',
            encoding="utf-8",
        )

        source_dir = fixture_root / "sources" / "realtime"
        source_dir.mkdir(parents=True)
        (source_dir / "fixture.txt").write_text("source fixture\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=source_dir, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.invalid"], cwd=source_dir, check=True)
        subprocess.run(["git", "config", "user.name", "Portable Beam Fixture"], cwd=source_dir, check=True)
        subprocess.run(["git", "add", "fixture.txt"], cwd=source_dir, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=source_dir, check=True)
        source_ref = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source_dir, text=True
        ).strip()

        fake_bin = fixture_root / "fake-bin"
        fake_bin.mkdir()
        (fake_bin / "nix").write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${1:-} == eval ]]; then printf '%s\\n' aarch64-darwin; exit 0; fi\n"
            "exit 1\n",
            encoding="utf-8",
        )
        nix_build = fake_bin / "nix-build"
        nix_build.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            'build_root="${1:?missing build root}"\n'
            '[ -f "$build_root/nix/portable-beam/beam-linux-fixup.sh" ]\n'
            '[ -f "$build_root/nix/portable-beam/beam-launcher.sh" ]\n'
            '[ -f "$build_root/fixture.txt" ]\n'
            '{ printf \'build-root=%s\\n\' "$build_root"; printf \'%s\\n\' "$build_root/nix/portable-beam/beam-linux-fixup.sh" "$build_root/nix/portable-beam/beam-launcher.sh"; } > "$FAKE_NIX_TRACE"\n'
            'out=""\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  if [[ $1 == --out-link ]]; then out=$2; shift 2; else shift; fi\n'
            'done\n'
            '[[ -n "$out" ]]\n'
            'mkdir -p "$out/bin"\n'
            "printf 'fixture\\n' > \"$out/bin/realtime\"\n"
            'chmod 0755 "$out/bin/realtime"\n',
            encoding="utf-8",
        )
        for command in (fake_bin / "nix", nix_build):
            command.chmod(0o755)
        bash_env = fixture_root / "bash-env"
        bash_env.write_text(
            "nix() {\n"
            "  if [[ ${1:-} == eval ]]; then printf '%s\\n' aarch64-darwin; return 0; fi\n"
            "  return 1\n"
            "}\n"
            'nix-build() { "$FAKE_NIX_BUILD" "$@"; }\n',
            encoding="utf-8",
        )

        version = f"local-overlay-{os.getpid()}"
        environment = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "BASH_ENV": str(bash_env),
            "FAKE_NIX_BUILD": str(nix_build),
            "SOURCE_REF": source_ref,
            "TARGET_OS": "darwin",
            "ARCH": "arm64",
            "NIX_RUNNER": "local",
            "ARTIFACT_ARCHIVE_ON_BUILD": "0",
            "FAKE_NIX_TRACE": str(self.temp / "local-overlay.trace"),
        }
        result = subprocess.run(
            ["bash", str(fixture_root / "scripts" / "build-artifact-from-nix.sh"), "realtime", version],
            cwd=fixture_root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        trace = (self.temp / "local-overlay.trace").read_text(encoding="utf-8").splitlines()
        self.assertTrue(trace[0].startswith("build-root="))
        self.assertTrue(pathlib.Path(trace[1]).is_file())
        self.assertTrue(pathlib.Path(trace[2]).is_file())
        manifest = json.loads(
            (fixture_root / "artifacts" / "realtime" / version / "darwin-arm64" / "manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(manifest["nix_auxiliary_overlays"], ["nix/portable-beam:nix/portable-beam"])

    def test_local_package_overlay_skips_empty_auxiliary_array_under_nounset(self):
        """Exercise local export with a package overlay and no auxiliary array."""
        fixture_root = self.temp / "local-empty-aux-repo"
        (fixture_root / "scripts").mkdir(parents=True)
        for name in (
            "build-artifact-from-nix.sh",
            "lib.sh",
            "prune-runtime-tree.sh",
            "generate-artifact-sbom.sh",
            "generate-artifact-sbom.py",
            "measure-artifact.sh",
        ):
            shutil.copy2(ROOT_DIR / "scripts" / name, fixture_root / "scripts" / name)
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(ROOT_DIR / name, fixture_root / name)

        package_overlay = fixture_root / "nix" / "package-overlay"
        package_overlay.mkdir(parents=True)
        (package_overlay / "marker.txt").write_text("package overlay\n", encoding="utf-8")
        service_dir = fixture_root / "services" / "vector"
        service_dir.mkdir(parents=True)
        (service_dir / "recipe.env").write_text(
            'SOURCE_DIR="sources/vector"\n'
            'SOURCE_REF="${SOURCE_REF:-fixture}"\n'
            'ARTIFACT_BACKEND="nix"\n'
            'BASE_IMAGE="scratch"\n'
            "ENTRYPOINT_JSON='[]'\n"
            "CMD_JSON='[]'\n"
            'NIX_FLAKE="."\n'
            'NIX_ATTR="fixture"\n'
            'NIX_BUILD_MODE="nix-build"\n'
            'NIX_EXPRESSION="."\n'
            'NIX_RUNNER="${NIX_RUNNER:-auto}"\n'
            'NIX_OUTPUT_KIND="rootfs"\n'
            "NIX_COPY_PATHS_JSON='[]'\n"
            'NIX_PACKAGE_OVERLAY="nix/package-overlay"\n'
            'NIX_PACKAGE_OVERLAY_DEST="nix/package-overlay"\n'
            'PORTABLE="true"\n',
            encoding="utf-8",
        )

        source_dir = fixture_root / "sources" / "vector"
        source_dir.mkdir(parents=True)
        (source_dir / "fixture.txt").write_text("source fixture\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=source_dir, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.invalid"], cwd=source_dir, check=True)
        subprocess.run(["git", "config", "user.name", "Empty Auxiliary Fixture"], cwd=source_dir, check=True)
        subprocess.run(["git", "add", "fixture.txt"], cwd=source_dir, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=source_dir, check=True)
        source_ref = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=source_dir, text=True
        ).strip()

        fake_bin = fixture_root / "fake-bin"
        fake_bin.mkdir()
        nix = fake_bin / "nix"
        nix.write_text(
            "#!/usr/bin/env bash\n"
            "if [[ ${1:-} == eval ]]; then printf '%s\\n' aarch64-darwin; exit 0; fi\n"
            "exit 1\n",
            encoding="utf-8",
        )
        nix_build = fake_bin / "nix-build"
        nix_build.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            'build_root="${1:?missing build root}"\n'
            '[ -f "$build_root/nix/package-overlay/marker.txt" ]\n'
            'out=""\n'
            'while [[ $# -gt 0 ]]; do\n'
            '  if [[ $1 == --out-link ]]; then out=$2; shift 2; else shift; fi\n'
            'done\n'
            '[[ -n "$out" ]]\n'
            'mkdir -p "$out/bin"\n'
            "printf 'fixture\\n' > \"$out/bin/vector\"\n"
            'chmod 0755 "$out/bin/vector"\n',
            encoding="utf-8",
        )
        for command in (nix, nix_build):
            command.chmod(0o755)
        bash_env = fixture_root / "bash-env"
        bash_env.write_text(
            "NIX_AUXILIARY_OVERLAYS=()\n"
            "nix() {\n"
            "  if [[ ${1:-} == eval ]]; then printf '%s\\n' aarch64-darwin; return 0; fi\n"
            "  return 1\n"
            "}\n"
            'nix-build() { "$FAKE_NIX_BUILD" "$@"; }\n',
            encoding="utf-8",
        )

        version = f"local-empty-aux-{os.getpid()}"
        environment = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "BASH_ENV": str(bash_env),
            "FAKE_NIX_BUILD": str(nix_build),
            "SOURCE_REF": source_ref,
            "TARGET_OS": "darwin",
            "ARCH": "arm64",
            "NIX_RUNNER": "local",
            "ARTIFACT_ARCHIVE_ON_BUILD": "0",
        }
        result = subprocess.run(
            ["bash", str(fixture_root / "scripts" / "build-artifact-from-nix.sh"), "vector", version],
            cwd=fixture_root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(
            (fixture_root / "artifacts" / "vector" / version / "darwin-arm64" / "manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(manifest["nix_auxiliary_overlays"], [])

    def test_fixup_generates_nested_launcher_with_artifact_root(self):
        """Run the shared fixup seam and execute its generated ERTS wrapper."""
        rootfs = self.temp / "generated-rootfs"
        erts_bin = rootfs / "erts-16.4.0.5" / "bin"
        erts_bin.mkdir(parents=True)
        real_beam = erts_bin / "beam.smp"
        real_beam.write_text(
            "#!/bin/sh\n"
            "printf 'beam-ok:%s\\n' \"$*\"\n",
            encoding="utf-8",
        )
        real_beam.chmod(0o755)

        glibc_root = self.temp / "glibc"
        glibc_lib = glibc_root / "lib"
        glibc_lib.mkdir(parents=True)
        glibc_loader = glibc_lib / "ld-linux-x86-64.so.2"
        glibc_loader.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "if [ \"${1:-}\" = --help ]; then printf '%s\\n' --argv0; exit 0; fi\n"
            "if [ \"${1:-}\" = --argv0 ]; then shift 2; fi\n"
            "if [ \"${1:-}\" = --library-path ]; then shift 2; fi\n"
            "if [ \"${1:-}\" = --list ]; then exit 0; fi\n"
            "exec \"$@\"\n",
            encoding="utf-8",
        )
        glibc_loader.chmod(0o755)
        (glibc_lib / "libc.so.6").write_text("glibc fixture", encoding="utf-8")
        locale_lib = self.temp / "glibc-locales" / "lib" / "locale"
        locale_lib.mkdir(parents=True)
        (locale_lib / "locale-archive").write_text("locale fixture", encoding="utf-8")
        tzdata = self.temp / "tzdata"
        tzdata.mkdir()
        (tzdata / "UTC").write_text("zone fixture", encoding="utf-8")

        def write_archive(path, files):
            with tarfile.open(path, "w") as archive:
                for name, contents in files.items():
                    member = tarfile.TarInfo(name)
                    member.size = len(contents.encode("utf-8"))
                    archive.addfile(member, io.BytesIO(contents.encode("utf-8")))

        glibc_archive = self.temp / "glibc-src.tar"
        compiler_archive = self.temp / "compiler-src.tar"
        tzdata_archive = self.temp / "tzdata-src.tar"
        write_archive(glibc_archive, {"glibc-2.40/COPYING.LIB": "glibc license"})
        write_archive(
            compiler_archive,
            {"gcc-14/COPYING.RUNTIME": "runtime license", "gcc-14/COPYING3": "gcc license"},
        )
        write_archive(tzdata_archive, {"LICENSE": "tzdata license"})

        fake_bin = self.temp / "fixup-tools"
        fake_bin.mkdir()
        tools = {
            "uname": "#!/bin/sh\nprintf '%s\\n' x86_64\n",
            "ldd": "#!/bin/sh\nexit 0\n",
            "strip": "#!/bin/sh\nexit 0\n",
            "patchelf": "#!/bin/sh\nexit 0\n",
            "readelf": "#!/bin/sh\nprintf '%s\\n' INTERP\n",
            "file": (
                "#!/bin/sh\n"
                "case \"$1\" in */erts-*/bin/*) printf '%s\\n' 'ELF 64-bit' ;; *) printf '%s\\n' data ;; esac\n"
            ),
        }
        for name, content in tools.items():
            path = fake_bin / name
            path.write_text(content, encoding="utf-8")
            path.chmod(0o755)

        environment = {
            **os.environ,
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "PORTABLE_BEAM_ROOTFS": str(rootfs),
            "PORTABLE_BEAM_GLIBC_LIB": str(glibc_lib),
            "PORTABLE_BEAM_GLIBC_SRC": str(glibc_archive),
            "PORTABLE_BEAM_COMPILER_SRC": str(compiler_archive),
            "PORTABLE_BEAM_TZDATA": str(tzdata),
            "PORTABLE_BEAM_TZDATA_SRC": str(tzdata_archive),
            "PORTABLE_BEAM_LOCALE_LIB": str(locale_lib),
            "PORTABLE_BEAM_LAUNCHER": str(LAUNCHER),
        }
        result = subprocess.run(
            ["bash", str(FIXUP)],
            cwd=ROOT_DIR,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        launcher = erts_bin / "beam.smp"
        self.assertTrue(launcher.is_file())
        self.assertTrue((erts_bin / ".beam.smp-portable-real").is_file())
        command = [str(launcher)] if pathlib.Path("/usr/bin/sh").exists() else ["/bin/sh", str(launcher)]
        launch = subprocess.run(
            [*command, "--version"],
            cwd=ROOT_DIR,
            env={**environment, "PATH": os.environ["PATH"]},
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(launch.returncode, 0, launch.stderr)
        self.assertEqual(launch.stdout, "beam-ok:--version\n")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PortableBeamLauncherTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
PY
