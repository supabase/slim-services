import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";

import { CHECKSUM_TYPE, NATIVE_TARGETS } from "./publish-native-oci.ts";

const ROOT = join(import.meta.dir, "..");
const SCRIPT = join(import.meta.dir, "ecr-mirror.ts");
const DIGEST = `sha256:${"a".repeat(64)}`;

const run = (args: ReadonlyArray<string>, env: Record<string, string> = {}) => {
  const merged: Record<string, string | undefined> = {
    ...process.env,
    PATH: "/usr/bin:/bin",
    ...env,
  };
  if (!("MIRROR_DISPATCH_TOKEN" in env)) delete merged["MIRROR_DISPATCH_TOKEN"];
  if (!("NATIVE_ARTIFACTS_FILE" in env)) delete merged["NATIVE_ARTIFACTS_FILE"];
  if (!("GITHUB_OUTPUT" in env)) delete merged["GITHUB_OUTPUT"];
  if (!("S3_MIRROR_BASE_URL" in env)) merged["S3_MIRROR_BASE_URL"] = "file:///nonexistent-slim-s3";
  const cleaned: Record<string, string> = {};
  for (const [key, value] of Object.entries(merged)) {
    if (value !== undefined) cleaned[key] = value;
  }
  return Bun.spawnSync([process.execPath, SCRIPT, ...args], {
    cwd: ROOT,
    env: cleaned,
    stdout: "pipe",
    stderr: "pipe",
  });
};

const writeStub = (dir: string, name: string, body: string): void => {
  writeFileSync(join(dir, name), body);
  chmodSync(join(dir, name), 0o755);
};

const SUMS = "sums\n";
const SUMS_DIGEST = `sha256:${new Bun.CryptoHasher("sha256").update(SUMS).digest("hex")}`;

// `regctl manifest get` branch returning a native manifest whose checksum layer is SUMS.
const NATIVE_MANIFEST_GET = `if [ "$1" = manifest ] && [ "$2" = get ]; then
  printf '%s\\n' '${JSON.stringify({ layers: [{ mediaType: CHECKSUM_TYPE, digest: SUMS_DIGEST }] })}'; exit 0
fi`;

/** Serves SUMS as every target's S3 SHA256SUMS object through a file:// base URL. */
const s3Mirror = (releases: ReadonlyArray<readonly [string, string]>): string => {
  const root = mkdtempSync(join(tmpdir(), "ecr-s3-"));
  for (const [service, version] of releases) {
    mkdirSync(join(root, service, version), { recursive: true });
    for (const target of NATIVE_TARGETS)
      writeFileSync(join(root, service, version, `${service}-${version}-${target}.SHA256SUMS`), SUMS);
  }
  return `file://${root}`;
};

describe("ecr-mirror payload", () => {
  test("renders a dispatch request without natives", () => {
    const result = run(["payload", "postgrest", "v16.2", DIGEST]);
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    const payload = JSON.parse(result.stdout.toString());
    expect(payload["event_type"]).toBe("mirror-slim-image");
    expect(payload["client_payload"]).toEqual({
      destination: "public.ecr.aws/supabase/cli/postgrest:v16.2",
      digest: DIGEST,
      service: "postgrest",
      source: "ghcr.io/supabase/cli/postgrest:v16.2",
      version: "v16.2",
    });
    expect(payload["client_payload"]["natives"]).toBeUndefined();
  });

  test("reads a published image digest", () => {
    const tmp = mkdtempSync(join(tmpdir(), "ecr-digest-"));
    const metadata = join(tmp, "published-image.json");
    writeFileSync(metadata, JSON.stringify({ image: "ghcr.io/supabase/cli/postgrest:v16.2", digest: DIGEST }));
    const result = run(["published-digest", metadata]);
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    expect(result.stdout.toString().trim()).toBe(DIGEST);
  });

  test("prints the ECR repository for a known service", () => {
    const result = run(["destination-repo", "postgrest"]);
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    expect(result.stdout.toString().trim()).toBe("public.ecr.aws/supabase/cli/postgrest");
  });

  test("honors prefix overrides", () => {
    const result = run(["payload", "auth", "v2.196.0", DIGEST], {
      MIRROR_EVENT_TYPE: "mirror-test",
      SOURCE_IMAGE_PREFIX: "ghcr.io/example/src",
      ECR_MIRROR_PREFIX: "public.ecr.aws/example/dst",
    });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    const payload = JSON.parse(result.stdout.toString());
    expect(payload["event_type"]).toBe("mirror-test");
    expect(payload["client_payload"]["source"]).toBe("ghcr.io/example/src/auth:v2.196.0");
    expect(payload["client_payload"]["destination"]).toBe("public.ecr.aws/example/dst/auth:v2.196.0");
  });

  test("rejects an unknown service", () => {
    const result = run(["payload", "kong", "v1.0.0", DIGEST]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("unknown release service");
  });

  test("rejects a disallowed version", () => {
    const result = run(["payload", "postgrest", "latest", DIGEST]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("not an allowed release tag");
  });

  test("rejects a malformed digest", () => {
    const result = run(["payload", "postgrest", "v16.2", "sha256:nope"]);
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("not a sha256 image digest");
  });

  test("includes validated natives", () => {
    const tmp = mkdtempSync(join(tmpdir(), "ecr-natives-"));
    const natives = join(tmp, "natives.json");
    const nativeDigest = `sha256:${"c".repeat(64)}`;
    writeFileSync(
      natives,
      JSON.stringify([{ tag: "v16.2-native-linux-arm64", digest: nativeDigest }]),
    );
    const result = run(["payload", "postgrest", "v16.2", DIGEST], {
      NATIVE_ARTIFACTS_FILE: natives,
    });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    expect(JSON.parse(result.stdout.toString())["client_payload"]["natives"]).toEqual([
      { tag: "v16.2-native-linux-arm64", digest: nativeDigest },
    ]);
  });

  test("rejects a native platform image tag", () => {
    const tmp = mkdtempSync(join(tmpdir(), "ecr-bad-native-"));
    const natives = join(tmp, "natives.json");
    writeFileSync(
      natives,
      JSON.stringify([{ tag: "v16.2-linux-arm64", digest: `sha256:${"c".repeat(64)}` }]),
    );
    const result = run(["payload", "postgrest", "v16.2", DIGEST], {
      NATIVE_ARTIFACTS_FILE: natives,
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("native tag does not match");
  });
});

describe("ecr-mirror request and verify", () => {
  test("requires a token when the destination is stale", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-req-"));
    writeStub(stub, "gh", "#!/usr/bin/env bash\nexit 1\n");
    writeStub(stub, "regctl", "#!/usr/bin/env bash\nexit 1\n");
    const result = run(["request", "postgrest", "v16.2", DIGEST], {
      PATH: `${stub}:/usr/bin:/bin`,
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stderr.toString()).toContain("MIRROR_DISPATCH_TOKEN is required");
  });

  test("dispatches when the destination already matches", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-match-"));
    const dispatched = join(stub, "dispatched");
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
exit 1
`,
    );
    writeStub(stub, "gh", `#!/bin/sh\ntouch '${dispatched}'\nexit 0\n`);
    const result = run(["request", "postgrest", "v16.2", DIGEST], {
      PATH: `${stub}:/usr/bin:/bin`,
      MIRROR_DISPATCH_TOKEN: "token",
      ECR_MIRROR_POLL_INTERVAL: "0",
      ECR_MIRROR_TIMEOUT: "30",
    });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    expect(existsSync(dispatched)).toBe(true);
    expect(result.stdout.toString()).not.toContain("destination already matches");
  });

  test("reports the image mirror and S3 natives independently", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-req-s3-"));
    const natives = join(stub, "natives.json");
    const output = join(stub, "github-output");
    const nativeDigest = `sha256:${"c".repeat(64)}`;
    writeFileSync(natives, JSON.stringify([{ tag: "v16.2-native-linux-arm64", digest: nativeDigest }]));
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
${NATIVE_MANIFEST_GET}
if [ "$1" = image ] && [ "$2" = digest ]; then
  case "$3" in *native*) printf "%s\\n" "${nativeDigest}"; exit 0 ;; esac
  [ -n "$FAKE_IMAGE" ] && printf "%s\\n" "$FAKE_IMAGE"; exit 0
fi
exit 1
`,
    );
    writeStub(stub, "gh", "#!/bin/sh\ncat >/dev/null\nexit 0\n");
    const env = {
      PATH: `${stub}:/usr/bin:/bin`,
      MIRROR_DISPATCH_TOKEN: "token",
      NATIVE_ARTIFACTS_FILE: natives,
      GITHUB_OUTPUT: output,
      ECR_MIRROR_POLL_INTERVAL: "0",
      ECR_MIRROR_TIMEOUT: "1",
    };

    const s3Stale = run(["request", "postgrest", "v16.2", DIGEST], { ...env, FAKE_IMAGE: DIGEST });
    expect(s3Stale.exitCode).not.toBe(0);
    expect(s3Stale.stderr.toString()).toContain("1 native artifact(s) missing");
    expect(readFileSync(output, "utf8")).toBe("mirrored=true\n");

    writeFileSync(output, "");
    const ecrDown = run(["request", "postgrest", "v16.2", DIGEST], {
      ...env,
      FAKE_IMAGE: "",
      S3_MIRROR_BASE_URL: s3Mirror([["postgrest", "v16.2"]]),
    });
    expect(ecrDown.exitCode).not.toBe(0);
    expect(ecrDown.stdout.toString()).toContain("in sync S3 native: postgrest v16.2 linux-arm64");
    expect(ecrDown.stderr.toString()).toContain("1 release image(s) are missing");
    expect(readFileSync(output, "utf8")).toBe("");
  });

  test("destination digest uses empty task-local configs", async () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-anon-"));
    const trace = join(stub, "regctl-trace");
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
regctl_empty=no; docker_empty=no
[ -d "\${REGCTL_CONFIG-}" ] && [ -z "$(ls -A "$REGCTL_CONFIG")" ] && regctl_empty=yes
[ -d "\${DOCKER_CONFIG-}" ] && [ -z "$(ls -A "$DOCKER_CONFIG")" ] && docker_empty=yes
printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$*" "\${REGCTL_CONFIG-}" "\${DOCKER_CONFIG-}" "$regctl_empty" "$docker_empty" >> "$FAKE_TRACE"
n=0; [ -f "$FAKE_TRACE.count" ] && n=$(cat "$FAKE_TRACE.count")
n=$((n + 1)); printf "%s\\n" "$n" > "$FAKE_TRACE.count"
if [ "$1" = image ] && [ "$2" = digest ] && [ "$n" -ge 2 ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "sha256:${"b".repeat(64)}"; exit 0; fi
exit 1
`,
    );
    const callerRegctl = join(stub, "caller-regctl");
    const callerDocker = join(stub, "caller-docker");
    mkdirSync(callerRegctl);
    mkdirSync(callerDocker);
    const result = run(["verify", "postgrest", "v16.2", DIGEST], {
      PATH: `${stub}:/usr/bin:/bin`,
      FAKE_TRACE: trace,
      REGCTL_CONFIG: callerRegctl,
      DOCKER_CONFIG: callerDocker,
      ECR_MIRROR_POLL_INTERVAL: "0",
      ECR_MIRROR_TIMEOUT: "30",
    });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    const destLines = (await Bun.file(trace).text())
      .split("\n")
      .map((line) => line.split("\t"))
      .filter((line) =>
        line[0]?.includes("image digest public.ecr.aws/supabase/cli/postgrest:v16.2"),
      );
    expect(destLines.length).toBeGreaterThanOrEqual(2);
    const last = destLines[destLines.length - 1] ?? [];
    const [, regctlConfig, dockerConfig, regctlEmpty, dockerEmpty] = last;
    expect(destLines[0]?.[1]).toBe(destLines[1]?.[1]);
    expect(regctlConfig).not.toBe(callerRegctl);
    expect(dockerConfig).not.toBe(callerDocker);
    expect(regctlEmpty).toBe("yes");
    expect(dockerEmpty).toBe("yes");
  });
});

describe("ecr-mirror sync", () => {
  test("lists a published tag outside the current pattern", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-sync-"));
    const stale = `sha256:${"b".repeat(64)}`;
    writeStub(
      stub,
      "gh",
      `#!/usr/bin/env bash
cat <<'EOF'
[[{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = manifest ] && [ "$2" = head ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "${stale}"; exit 0; fi
exit 1
`,
    );
    const result = run(["sync"], { PATH: `${stub}:/usr/bin:/bin` });
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout.toString()).toContain("out of sync: postgres 15.14.1.159");
    expect(result.stderr.toString()).not.toContain("no published releases found");
  });

  test("reports native ECR drift without failing unless natives are required", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-native-drift-"));
    const nativeDigest = `sha256:${"c".repeat(64)}`;
    writeStub(
      stub,
      "gh",
      `#!/usr/bin/env bash
cat <<'EOF'
[[{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = manifest ] && [ "$2" = head ]; then
  case "$3" in *native*) printf "%s\\n" "${nativeDigest}"; exit 0 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
${NATIVE_MANIFEST_GET}
if [ "$1" = image ] && [ "$2" = digest ]; then
  case "$3" in *native*) printf "%s\\n" "sha256:${"b".repeat(64)}"; exit 0 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
exit 1
`,
    );
    const s3 = s3Mirror([["postgres", "15.14.1.159"]]);
    const result = run(["sync"], { PATH: `${stub}:/usr/bin:/bin`, S3_MIRROR_BASE_URL: s3 });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    expect(result.stdout.toString()).toContain(
      "out of sync native: postgres 15.14.1.159-native-linux-arm64",
    );
    expect(result.stdout.toString()).toContain("in sync S3 native: postgres 15.14.1.159 linux-arm64");
    expect(result.stdout.toString()).toContain("3 native tag(s) missing from public.ecr.aws/supabase/cli");

    const required = run(["sync"], {
      PATH: `${stub}:/usr/bin:/bin`,
      S3_MIRROR_BASE_URL: s3,
      ECR_MIRROR_REQUIRE_NATIVES: "1",
    });
    expect(required.exitCode).not.toBe(0);
    expect(required.stderr.toString()).toContain("native tag(s) missing");
  });

  test("skips a release without a source image and audits the rest", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-skip-"));
    writeStub(
      stub,
      "gh",
      `#!/usr/bin/env bash
cat <<'EOF'
[[{"tag_name":"postgres-15.8.1.085","draft":false,"prerelease":false},{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
case "$3" in *15.8.1.085*) exit 1 ;; esac
if [ "$1" = manifest ] && [ "$2" = head ]; then
  case "$3" in *native*) exit 1 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
exit 1
`,
    );
    const result = run(["sync", "--all"], { PATH: `${stub}:/usr/bin:/bin` });
    expect(result.exitCode, result.stderr.toString() + result.stdout.toString()).toBe(0);
    expect(result.stdout.toString()).toContain("skipped: postgres 15.8.1.085 has no source image");
    expect(result.stdout.toString()).toContain("in sync: postgres 15.14.1.159");
    expect(result.stdout.toString()).toContain("skipped 1 release(s) without a source image");
  });

  test("--request does not wait for natives unless required", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-nowait-"));
    const nativeDigest = `sha256:${"c".repeat(64)}`;
    writeStub(
      stub,
      "gh",
      `#!/bin/sh
case "$*" in *dispatches*) cat >/dev/null; exit 0 ;; esac
cat <<'EOF'
[[{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = manifest ] && [ "$2" = head ]; then
  case "$3" in *native*) printf "%s\\n" "${nativeDigest}"; exit 0 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
${NATIVE_MANIFEST_GET}
if [ "$1" = image ] && [ "$2" = digest ]; then
  case "$3" in *native*) printf "%s\\n" "sha256:${"b".repeat(64)}"; exit 0 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
exit 1
`,
    );
    const result = run(["sync", "--request"], {
      PATH: `${stub}:/usr/bin:/bin`,
      S3_MIRROR_BASE_URL: s3Mirror([["postgres", "15.14.1.159"]]),
      MIRROR_DISPATCH_TOKEN: "token",
      ECR_MIRROR_POLL_INTERVAL: "0",
      ECR_MIRROR_TIMEOUT: "1",
    });
    expect(result.exitCode, result.stderr.toString() + result.stdout.toString()).toBe(0);
    expect(result.stdout.toString()).not.toContain("waiting for");
    expect(result.stdout.toString()).toContain("3 native tag(s) missing from public.ecr.aws/supabase/cli");
  });

  test("fails --request when natives remain stale and are required", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-stale-"));
    const nativeDigest = `sha256:${"c".repeat(64)}`;
    writeStub(
      stub,
      "gh",
      `#!/bin/sh
case "$*" in *dispatches*) cat >/dev/null; exit 0 ;; esac
cat <<'EOF'
[[{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = manifest ] && [ "$2" = head ]; then
  case "$3" in *native*) printf "%s\\n" "${nativeDigest}"; exit 0 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
${NATIVE_MANIFEST_GET}
if [ "$1" = image ] && [ "$2" = digest ]; then
  case "$3" in *native*) printf "%s\\n" "sha256:${"b".repeat(64)}"; exit 0 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
exit 1
`,
    );
    const result = run(["sync", "--request"], {
      PATH: `${stub}:/usr/bin:/bin`,
      S3_MIRROR_BASE_URL: s3Mirror([["postgres", "15.14.1.159"]]),
      MIRROR_DISPATCH_TOKEN: "token",
      ECR_MIRROR_POLL_INTERVAL: "0",
      ECR_MIRROR_TIMEOUT: "1",
      ECR_MIRROR_REQUIRE_NATIVES: "1",
    });
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout.toString()).toContain("waiting for postgres 15.14.1.159-native-linux-arm64 native");
    expect(result.stderr.toString()).toContain("native tag(s) missing");
  });

  test("waits until natives match after dispatch", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-wait-"));
    const nativeDigest = `sha256:${"c".repeat(64)}`;
    writeStub(
      stub,
      "gh",
      `#!/bin/sh
case "$*" in *dispatches*) cat >/dev/null; exit 0 ;; esac
cat <<'EOF'
[[{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = manifest ] && [ "$2" = head ]; then
  case "$3" in *native*) printf "%s\\n" "${nativeDigest}"; exit 0 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
${NATIVE_MANIFEST_GET}
if [ "$1" = image ] && [ "$2" = digest ]; then
  case "$3" in *native*)
    n=0; [ -f "$FAKE_COUNT" ] && n=$(cat "$FAKE_COUNT")
    n=$((n + 1)); printf "%s\\n" "$n" > "$FAKE_COUNT"
    if [ "$n" -ge 7 ]; then printf "%s\\n" "${nativeDigest}"; exit 0; fi
    printf "%s\\n" "sha256:${"b".repeat(64)}"; exit 0 ;;
  esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
exit 1
`,
    );
    const result = run(["sync", "--request"], {
      PATH: `${stub}:/usr/bin:/bin`,
      S3_MIRROR_BASE_URL: s3Mirror([["postgres", "15.14.1.159"]]),
      FAKE_COUNT: join(stub, "native-dest.count"),
      MIRROR_DISPATCH_TOKEN: "token",
      ECR_MIRROR_POLL_INTERVAL: "0",
      ECR_MIRROR_TIMEOUT: "30",
      ECR_MIRROR_REQUIRE_NATIVES: "1",
    });
    expect(result.exitCode, result.stderr.toString() + result.stdout.toString()).toBe(0);
    expect(result.stdout.toString()).toContain("waiting for postgres 15.14.1.159-native-linux-arm64 native");
    expect(result.stdout.toString()).toContain(
      "in sync native: postgres 15.14.1.159-native-linux-arm64",
    );
  });

  test("fails on S3 native drift while ECR Public is in sync", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-s3-drift-"));
    writeStub(
      stub,
      "gh",
      `#!/usr/bin/env bash
cat <<'EOF'
[[{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = manifest ] && [ "$2" = head ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
${NATIVE_MANIFEST_GET}
if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
exit 1
`,
    );
    const result = run(["sync"], { PATH: `${stub}:/usr/bin:/bin` });
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout.toString()).toContain("in sync native: postgres 15.14.1.159-native-linux-arm64");
    expect(result.stdout.toString()).toContain("out of sync S3 native: postgres 15.14.1.159 linux-arm64");
    expect(result.stderr.toString()).toContain("3 native artifact(s) missing from file:///nonexistent-slim-s3");
    expect(result.stderr.toString()).not.toContain("release image(s)");
  });

  test("--request dispatches every release before waiting when ECR Public never converges", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-outage-"));
    const dispatches = join(stub, "dispatches");
    writeStub(
      stub,
      "gh",
      `#!/bin/sh
case "$*" in *dispatches*) cat >> '${dispatches}'; exit 0 ;; esac
cat <<'EOF'
[[{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false},{"tag_name":"postgrest-v16.2","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = manifest ] && [ "$2" = head ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
${NATIVE_MANIFEST_GET}
exit 1
`,
    );
    const result = run(["sync", "--request"], {
      PATH: `${stub}:/usr/bin:/bin`,
      S3_MIRROR_BASE_URL: s3Mirror([
        ["postgres", "15.14.1.159"],
        ["postgrest", "v16.2"],
      ]),
      MIRROR_DISPATCH_TOKEN: "token",
      ECR_MIRROR_POLL_INTERVAL: "0",
      ECR_MIRROR_TIMEOUT: "1",
    });
    expect(result.exitCode).not.toBe(0);
    const sent = readFileSync(dispatches, "utf8");
    expect(sent).toContain('"source": "ghcr.io/supabase/cli/postgres:15.14.1.159"');
    expect(sent).toContain('"source": "ghcr.io/supabase/cli/postgrest:v16.2"');
    expect(result.stdout.toString()).toContain("in sync S3 native: postgrest v16.2 linux-amd64");
    expect(result.stderr.toString()).toContain(
      "2 release image(s) are missing from public.ecr.aws/supabase/cli",
    );
    expect(result.stderr.toString()).not.toContain("native artifact(s) missing");
  });

  test("audits the latest release of each line unless asked for all or one release", () => {
    const stub = mkdtempSync(join(tmpdir(), "ecr-filter-"));
    writeStub(
      stub,
      "gh",
      `#!/usr/bin/env bash
cat <<'EOF'
[[{"tag_name":"postgrest-v16.1","draft":false,"prerelease":false,"published_at":"2026-09-20T00:00:00Z"},{"tag_name":"postgrest-v16.2","draft":false,"prerelease":false,"published_at":"2026-09-01T00:00:00Z"},{"tag_name":"postgres-15.14.1.159","draft":false,"prerelease":false},{"tag_name":"postgres-15.14.1.160","draft":false,"prerelease":false},{"tag_name":"postgres-17.6.1.173","draft":false,"prerelease":false},{"tag_name":"postgres-17.9.0.012-orioledb","draft":false,"prerelease":false},{"tag_name":"postgres-17.9.0.028-orioledb","draft":false,"prerelease":false},{"tag_name":"postgres-16.0.0.001","draft":false,"prerelease":false}]]
EOF
`,
    );
    writeStub(
      stub,
      "regctl",
      `#!/bin/sh
if [ "$1" = manifest ] && [ "$2" = head ]; then
  case "$3" in *native*) exit 1 ;; esac
  printf "%s\\n" "${DIGEST}"; exit 0
fi
if [ "$1" = image ] && [ "$2" = digest ]; then printf "%s\\n" "${DIGEST}"; exit 0; fi
exit 1
`,
    );
    const latest = run(["sync"], { PATH: `${stub}:/usr/bin:/bin` });
    expect(latest.exitCode, latest.stderr.toString()).toBe(0);
    const audited = latest.stdout
      .toString()
      .split("\n")
      .filter((line) => line.startsWith("[slim] in sync: "))
      .map((line) => line.slice("[slim] in sync: ".length).split(" (")[0]);
    expect(audited.sort()).toEqual([
      "postgres 15.14.1.160",
      "postgres 17.6.1.173",
      "postgres 17.9.0.028-orioledb",
      "postgrest v16.2",
    ]);

    const result = run(["sync", "postgrest"], { PATH: `${stub}:/usr/bin:/bin` });
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    expect(result.stdout.toString()).toContain("in sync: postgrest v16.2");
    expect(result.stdout.toString()).not.toContain("v16.1");
    expect(result.stdout.toString()).not.toContain("postgres 15.14.1.160");

    const all = run(["sync", "--all", "postgrest"], { PATH: `${stub}:/usr/bin:/bin` });
    expect(all.exitCode, all.stderr.toString()).toBe(0);
    expect(all.stdout.toString()).toContain("in sync: postgrest v16.1");
    expect(all.stdout.toString()).toContain("in sync: postgrest v16.2");

    const release = run(["sync", "postgrest:v16.1"], { PATH: `${stub}:/usr/bin:/bin` });
    expect(release.exitCode, release.stderr.toString()).toBe(0);
    expect(release.stdout.toString()).toContain("in sync: postgrest v16.1");
    expect(release.stdout.toString()).not.toContain("v16.2");

    const unknown = run(["sync", "kong"], { PATH: `${stub}:/usr/bin:/bin` });
    expect(unknown.exitCode).not.toBe(0);
    expect(unknown.stderr.toString()).toContain("unknown release service: kong");
  });
});
