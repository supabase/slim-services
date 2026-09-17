#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT_DIR = pathlib.Path(sys.argv[1])
sys.argv[1:] = []
SCRIPT = ROOT_DIR / "scripts" / "publish-native-oci.sh"


def run(*args, env=None, cwd=None):
    return subprocess.run(
        [str(SCRIPT), *args],
        capture_output=True,
        text=True,
        cwd=cwd or ROOT_DIR,
        env={"PATH": "/usr/bin:/bin", **(env or {})},
    )


class PublishNativeOci(unittest.TestCase):
    def test_pushes_each_present_triplet_and_skips_missing_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = pathlib.Path(tmp)
            assets = tmp / "assets"
            assets.mkdir()
            (assets / "postgrest-v16.2-linux-arm64.tar.zst").write_bytes(b"archive")
            (assets / "postgrest-v16.2-linux-arm64.manifest.json").write_text(
                "{}", encoding="utf-8"
            )
            (assets / "postgrest-v16.2-linux-arm64.SHA256SUMS").write_text(
                "deadbeef  postgrest-v16.2-linux-arm64.tar.zst\n",
                encoding="utf-8",
            )
            stub = tmp / "bin"
            stub.mkdir()
            puts = tmp / "puts"
            digest = "sha256:" + "a" * 64
            (stub / "regctl").write_text(
                "#!/bin/sh\n"
                'if [ "$1" = artifact ] && [ "$2" = put ]; then\n'
                '  printf "%s\\n" "$@" >> "$FAKE_PUTS"\n'
                "  exit 0\n"
                "fi\n"
                f'if [ "$1" = manifest ] && [ "$2" = head ]; then printf "%s\\n" "{digest}"; exit 0; fi\n'
                "exit 1\n",
                encoding="utf-8",
            )
            (stub / "regctl").chmod(0o755)
            output = tmp / "published-natives.json"
            result = run(
                "postgrest",
                "v16.2",
                "ghcr.io/supabase/cli/postgrest",
                str(assets),
                str(output),
                env={
                    "PATH": f"{stub}:/usr/bin:/bin",
                    "FAKE_PUTS": str(puts),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")),
                [{"tag": "v16.2-native-linux-arm64", "digest": digest}],
            )
            recorded = puts.read_text(encoding="utf-8")
            archive = assets / "postgrest-v16.2-linux-arm64.tar.zst"
            manifest = assets / "postgrest-v16.2-linux-arm64.manifest.json"
            checksum = assets / "postgrest-v16.2-linux-arm64.SHA256SUMS"
            self.assertEqual(
                recorded.splitlines(),
                [
                    "artifact",
                    "put",
                    "--artifact-type",
                    "application/vnd.supabase.slim.native.v1",
                    "--file",
                    str(archive),
                    "--file-media-type",
                    "application/vnd.supabase.slim.archive.v1.tar+zstd",
                    "--file",
                    str(manifest),
                    "--file-media-type",
                    "application/vnd.supabase.slim.manifest.v1+json",
                    "--file",
                    str(checksum),
                    "--file-media-type",
                    "application/vnd.supabase.slim.checksum.v1",
                    "ghcr.io/supabase/cli/postgrest:v16.2-native-linux-arm64",
                ],
            )
            self.assertIn("skipping linux-amd64", result.stdout)
            self.assertIn("skipping darwin-arm64", result.stdout)

    def test_rejects_an_invalid_service_name(self):
        result = run(
            "PostgREST",
            "v16.2",
            "ghcr.io/supabase/cli/postgrest",
            ".",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid service name", result.stderr)


unittest.main(verbosity=2)
PY
