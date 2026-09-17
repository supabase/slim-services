import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

const ROOT = join(import.meta.dir, "..");
const SCRIPT = join(import.meta.dir, "publish-native-oci.ts");
const DIGEST = `sha256:${"a".repeat(64)}`;

const run = (args: ReadonlyArray<string>, env: Record<string, string> = {}) =>
  Bun.spawnSync([process.execPath, SCRIPT, ...args], {
    cwd: ROOT,
    env: { PATH: "/usr/bin:/bin", TMPDIR: process.env["TMPDIR"] ?? tmpdir(), ...env },
    stdout: "pipe",
    stderr: "pipe",
  });

describe("publish-native-oci", () => {
  test("pushes each present triplet and skips missing targets", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "publish-native-"));
    const assets = join(tmp, "assets");
    mkdirSync(assets);
    const archive = join(assets, "postgrest-v16.2-linux-arm64.tar.zst");
    const manifest = join(assets, "postgrest-v16.2-linux-arm64.manifest.json");
    const checksum = join(assets, "postgrest-v16.2-linux-arm64.SHA256SUMS");
    writeFileSync(archive, "archive");
    writeFileSync(manifest, "{}");
    writeFileSync(checksum, "deadbeef  postgrest-v16.2-linux-arm64.tar.zst\n");
    const stub = join(tmp, "bin");
    mkdirSync(stub);
    const puts = join(tmp, "puts");
    writeFileSync(
      join(stub, "regctl"),
      `#!/bin/sh
if [ "$1" = artifact ] && [ "$2" = put ]; then
  printf "%s\\n" "$@" >> "$FAKE_PUTS"
  exit 0
fi
if [ "$1" = manifest ] && [ "$2" = head ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
exit 1
`,
    );
    chmodSync(join(stub, "regctl"), 0o755);
    const output = join(tmp, "published-natives.json");
    const result = run(
      ["postgrest", "v16.2", "ghcr.io/supabase/cli/postgrest", assets, output],
      { PATH: `${stub}:/usr/bin:/bin`, FAKE_PUTS: puts },
    );
    expect(result.exitCode, result.stderr.toString() + result.stdout.toString()).toBe(0);
    expect(JSON.parse(await Bun.file(output).text())).toEqual([
      { tag: "v16.2-native-linux-arm64", digest: DIGEST },
    ]);
    expect((await Bun.file(puts).text()).split("\n").filter(Boolean)).toEqual([
      "artifact",
      "put",
      "--artifact-type",
      "application/vnd.supabase.slim.native.v1",
      "--file",
      archive,
      "--file-media-type",
      "application/vnd.supabase.slim.archive.v1.tar+zstd",
      "--file",
      manifest,
      "--file-media-type",
      "application/vnd.supabase.slim.manifest.v1+json",
      "--file",
      checksum,
      "--file-media-type",
      "application/vnd.supabase.slim.checksum.v1",
      "ghcr.io/supabase/cli/postgrest:v16.2-native-linux-arm64",
    ]);
    expect(result.stdout.toString()).toContain("skipping linux-amd64");
    expect(result.stdout.toString()).toContain("skipping darwin-arm64");
  });

  test("rejects an invalid service name", () => {
    const result = run(["PostgREST", "v16.2", "ghcr.io/supabase/cli/postgrest", "."]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("invalid service name");
  });

  test("rejects a file passed as the assets directory", () => {
    const tmp = mkdtempSync(join(tmpdir(), "publish-native-file-"));
    const file = join(tmp, "not-a-dir.tar.zst");
    writeFileSync(file, "nope");
    const result = run(["postgrest", "v16.2", "ghcr.io/supabase/cli/postgrest", file]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("assets directory not found");
  });
});
