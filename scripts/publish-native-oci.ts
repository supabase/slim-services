/**
 * Push each native triplet (tar.zst + manifest.json + SHA256SUMS) to
 * IMAGE_REPOSITORY:<VERSION>-native-<target>. Do not use <VERSION>-linux-*
 * tags; those are image platform manifests.
 *
 * Run: `bun scripts/publish-native-oci.ts SERVICE VERSION IMAGE_REPOSITORY ASSETS_DIR [OUTPUT_JSON]`
 */

import { existsSync, statSync } from "node:fs";
import { join } from "node:path";

import { DIGEST_PATTERN, NATIVE_TARGETS, ScriptError } from "./slim-native.ts";

export { NATIVE_TARGETS, ScriptError } from "./slim-native.ts";

export const ARCHIVE_TYPE = "application/vnd.supabase.slim.archive.v1.tar+zstd";
export const MANIFEST_TYPE = "application/vnd.supabase.slim.manifest.v1+json";
export const CHECKSUM_TYPE = "application/vnd.supabase.slim.checksum.v1";
export const ARTIFACT_TYPE = "application/vnd.supabase.slim.native.v1";

const SERVICE_PATTERN = /^[a-z][a-z0-9-]*$/;
const VERSION_PATTERN = /^[A-Za-z0-9._-]+$/;

export type NativePublishRow = { readonly tag: string; readonly digest: string };

export type RunCommand = (
  argv: ReadonlyArray<string>,
) => { readonly ok: boolean; readonly stdout: string; readonly stderr: string };

const usage = `Usage:
  bun scripts/publish-native-oci.ts SERVICE VERSION IMAGE_REPOSITORY ASSETS_DIR [OUTPUT_JSON]

Push each native triplet (tar.zst + manifest.json + SHA256SUMS) to
IMAGE_REPOSITORY:<VERSION>-native-<target>. Writes OUTPUT_JSON
(default: published-natives.json) as [{tag,digest}, ...]. Missing
platforms are skipped. Never prune untagged manifests.`;

export const artifactPutArgv = (
  archive: string,
  manifest: string,
  checksum: string,
  ref: string,
): ReadonlyArray<string> => [
  "regctl",
  "artifact",
  "put",
  "--artifact-type",
  ARTIFACT_TYPE,
  "--file",
  archive,
  "--file-media-type",
  ARCHIVE_TYPE,
  "--file",
  manifest,
  "--file-media-type",
  MANIFEST_TYPE,
  "--file",
  checksum,
  "--file-media-type",
  CHECKSUM_TYPE,
  ref,
];

export const publishNativeOci = async (options: {
  readonly service: string;
  readonly version: string;
  readonly imageRepository: string;
  readonly assetsDir: string;
  readonly outputJson: string;
  readonly run: RunCommand;
  readonly log?: (message: string) => void;
}): Promise<ReadonlyArray<NativePublishRow>> => {
  const log = options.log ?? ((message) => console.log(`[slim] ${message}`));
  if (!existsSync(options.assetsDir) || !statSync(options.assetsDir).isDirectory())
    throw new ScriptError(`assets directory not found: ${options.assetsDir}`);
  if (!SERVICE_PATTERN.test(options.service))
    throw new ScriptError(`invalid service name: ${options.service}`);
  if (!VERSION_PATTERN.test(options.version))
    throw new ScriptError(`invalid version: ${options.version}`);

  const rows: NativePublishRow[] = [];
  for (const target of NATIVE_TARGETS) {
    const archive = join(
      options.assetsDir,
      `${options.service}-${options.version}-${target}.tar.zst`,
    );
    const manifest = join(
      options.assetsDir,
      `${options.service}-${options.version}-${target}.manifest.json`,
    );
    const checksum = join(
      options.assetsDir,
      `${options.service}-${options.version}-${target}.SHA256SUMS`,
    );
    if (!existsSync(archive) || !existsSync(manifest) || !existsSync(checksum)) {
      log(`skipping ${target}: native triplet not in ${options.assetsDir}`);
      continue;
    }
    const tag = `${options.version}-native-${target}`;
    const ref = `${options.imageRepository}:${tag}`;
    log(`publishing ${ref}`);
    const put = options.run(artifactPutArgv(archive, manifest, checksum, ref));
    if (!put.ok) throw new ScriptError(put.stderr.trim() || `regctl artifact put failed for ${ref}`);
    const head = options.run(["regctl", "manifest", "head", ref]);
    const digest = head.stdout.trim();
    if (!head.ok || !DIGEST_PATTERN.test(digest))
      throw new ScriptError(`could not resolve digest for ${ref}`);
    rows.push({ tag, digest });
  }
  await Bun.write(options.outputJson, `${JSON.stringify(rows, null, 2)}\n`);
  log(`wrote ${options.outputJson}`);
  return rows;
};

const spawn: RunCommand = (argv) => {
  const proc = Bun.spawnSync([...argv], { stdout: "pipe", stderr: "pipe" });
  return {
    ok: proc.exitCode === 0,
    stdout: proc.stdout.toString(),
    stderr: proc.stderr.toString(),
  };
};

if (import.meta.main) {
  const argv = process.argv.slice(2);
  if (argv[0] === "-h" || argv[0] === "--help") {
    console.log(usage);
    process.exit(0);
  }
  if (argv.length < 4 || argv.length > 5) {
    console.error(usage);
    process.exit(2);
  }
  try {
    await publishNativeOci({
      service: argv[0] ?? "",
      version: argv[1] ?? "",
      imageRepository: argv[2] ?? "",
      assetsDir: argv[3] ?? "",
      outputJson: argv[4] ?? "published-natives.json",
      run: spawn,
    });
  } catch (cause) {
    const error = cause instanceof ScriptError ? cause : new ScriptError(String(cause));
    console.error(`[slim] ERROR: ${error.message}`);
    process.exit(error.exitCode);
  }
}
