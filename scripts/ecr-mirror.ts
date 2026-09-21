/**
 * Mirror published slim images and native OCI tags to AWS ECR Public through
 * the mirror workflow hosted in the dispatch repository (supabase/cli by
 * default). Always dispatch: an unchanged image digest must not skip the
 * request, because native tags may have moved. Never prune untagged
 * manifests; already-shipped CLIs still pin those digests.
 *
 * Run: `bun scripts/ecr-mirror.ts payload|published-digest|destination-repo|request|verify|sync …`
 */

import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { DIGEST_PATTERN, NATIVE_TARGETS, ScriptError } from "./slim-native.ts";

export { NATIVE_TARGETS, ScriptError } from "./slim-native.ts";

export type NativeArtifact = { readonly tag: string; readonly digest: string };

export type CommandResult = {
  readonly ok: boolean;
  readonly stdout: string;
  readonly stderr: string;
};

export type RunCommand = (
  argv: ReadonlyArray<string>,
  options?: { readonly env?: Readonly<Record<string, string>>; readonly stdin?: string },
) => CommandResult;

const usage = `Usage:
  bun scripts/ecr-mirror.ts payload SERVICE VERSION DIGEST
  bun scripts/ecr-mirror.ts published-digest IMAGE_JSON
  bun scripts/ecr-mirror.ts destination-repo SERVICE
  bun scripts/ecr-mirror.ts request SERVICE VERSION DIGEST
  bun scripts/ecr-mirror.ts verify SERVICE VERSION DIGEST
  bun scripts/ecr-mirror.ts sync [--request]

Mirror published slim images and native OCI tags to AWS ECR Public through
the mirror workflow hosted in the dispatch repository (supabase/cli by
default). Always dispatch: an unchanged image digest must not skip the
request, because native tags may have moved. Never prune untagged
manifests; already-shipped CLIs still pin those digests.

sync audits every published GitHub Release. A release whose GHCR image is
missing is skipped and counted, not fatal. Native tag drift is reported
but only fails the audit (and, with --request, only waits for the native
copy) when ECR_MIRROR_REQUIRE_NATIVES=1; the cli handler copies natives
best-effort.`;

const log = (message: string): void => {
  console.log(`[slim] ${message}`);
};

const fail = (message: string): never => {
  throw new ScriptError(message);
};

const envString = (key: string, fallback: string): string => {
  const value = process.env[key];
  return value === undefined || value.trim() === "" ? fallback : value;
};

const envNumber = (key: string, fallback: number): number => {
  const raw = process.env[key];
  if (raw === undefined || raw.trim() === "") return fallback;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
};

const escapeRegExp = (value: string): string => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

export const nativeTagPattern = (version: string): RegExp =>
  new RegExp(`^${escapeRegExp(version)}-native-(${NATIVE_TARGETS.join("|")})$`);

type ServiceConfig = { readonly tag_pattern: string };
type ReleaseConfig = { readonly services: Readonly<Record<string, ServiceConfig>> };

export const loadReleaseConfig = (path: string): ReleaseConfig => {
  const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (typeof parsed !== "object" || parsed === null || !("services" in parsed))
    throw new ScriptError(`service release config not found: ${path}`);
  return parsed as ReleaseConfig;
};

export const validateRelease = (config: ReleaseConfig, service: string, version: string): void => {
  const entry = config.services[service];
  if (entry === undefined) throw new ScriptError(`unknown release service: ${service}`);
  if (!new RegExp(entry.tag_pattern).test(version))
    throw new ScriptError(`version is not an allowed release tag for ${service}: ${version}`);
};

export const validateDigest = (digest: string): void => {
  if (!DIGEST_PATTERN.test(digest)) throw new ScriptError(`not a sha256 image digest: ${digest}`);
};

export const publishedDigest = (path: string): string => {
  const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (typeof parsed !== "object" || parsed === null || !("digest" in parsed))
    throw new ScriptError(`digest missing in ${path}`);
  const digest = (parsed as { digest: unknown }).digest;
  if (typeof digest !== "string") throw new ScriptError(`digest missing in ${path}`);
  validateDigest(digest);
  return digest;
};

export const parseNatives = (raw: unknown, version: string): ReadonlyArray<NativeArtifact> => {
  if (!Array.isArray(raw)) throw new ScriptError("natives must be a JSON array");
  const tagRe = nativeTagPattern(version);
  const cleaned: NativeArtifact[] = [];
  for (const item of raw) {
    if (typeof item !== "object" || item === null || !("tag" in item) || !("digest" in item))
      throw new ScriptError(`invalid native entry: ${JSON.stringify(item)}`);
    const tag = (item as { tag: unknown }).tag;
    const digest = (item as { digest: unknown }).digest;
    if (typeof tag !== "string" || !tagRe.test(tag))
      throw new ScriptError(`native tag does not match ${version}-native-<target>: ${String(tag)}`);
    if (typeof digest !== "string" || !DIGEST_PATTERN.test(digest))
      throw new ScriptError(`not a sha256 native digest: ${String(digest)}`);
    cleaned.push({ tag, digest });
  }
  return cleaned;
};

export const renderPayload = (options: {
  readonly eventType: string;
  readonly service: string;
  readonly version: string;
  readonly source: string;
  readonly digest: string;
  readonly destination: string;
  readonly natives?: ReadonlyArray<NativeArtifact>;
}): unknown => {
  const client_payload: Record<string, unknown> = {
    destination: options.destination,
    digest: options.digest,
    service: options.service,
    source: options.source,
    version: options.version,
  };
  if (options.natives !== undefined) client_payload["natives"] = options.natives;
  return { client_payload, event_type: options.eventType };
};

export const publishedReleases = (
  config: ReleaseConfig,
  releasePages: unknown,
): ReadonlyArray<{ readonly service: string; readonly version: string }> => {
  const prefixes = Object.keys(config.services)
    .map((name) => ({ prefix: `${name}-`, service: name }))
    .sort((left, right) => right.prefix.length - left.prefix.length);
  if (!Array.isArray(releasePages)) return [];
  const rows: Array<{ service: string; version: string }> = [];
  for (const page of releasePages) {
    if (!Array.isArray(page)) continue;
    for (const release of page) {
      if (typeof release !== "object" || release === null) continue;
      const record = release as { tag_name?: unknown; draft?: unknown; prerelease?: unknown };
      if (record.draft || record.prerelease) continue;
      const tag = typeof record.tag_name === "string" ? record.tag_name : "";
      for (const { prefix, service } of prefixes) {
        if (tag.startsWith(prefix)) {
          rows.push({ service, version: tag.slice(prefix.length) });
          break;
        }
      }
    }
  }
  return rows;
};

const defaultSpawn: RunCommand = (argv, options) => {
  const env = { ...process.env, ...(options?.env ?? {}) } as Record<string, string | undefined>;
  const cleaned: Record<string, string> = {};
  for (const [key, value] of Object.entries(env)) {
    if (value !== undefined) cleaned[key] = value;
  }
  const proc = Bun.spawnSync([...argv], {
    cwd: process.cwd(),
    env: cleaned,
    stdin: options?.stdin === undefined ? "ignore" : new TextEncoder().encode(options.stdin),
    stdout: "pipe",
    stderr: "pipe",
  });
  return {
    ok: proc.exitCode === 0,
    stdout: proc.stdout.toString(),
    stderr: proc.stderr.toString(),
  };
};

type Context = {
  readonly config: ReleaseConfig;
  readonly dispatchRepo: string;
  readonly eventType: string;
  readonly sourcePrefix: string;
  readonly destPrefix: string;
  readonly timeoutSec: number;
  readonly pollSec: number;
  readonly requireNatives: boolean;
  readonly nativesFile: string | undefined;
  readonly token: string | undefined;
  readonly githubRepository: string;
  readonly run: RunCommand;
  anonRegctl: string;
  anonDocker: string;
};

const ensureAnon = (ctx: Context): void => {
  if (ctx.anonRegctl === "") {
    ctx.anonRegctl = mkdtempSync(join(tmpdir(), "slim-ecr-anon-regctl-"));
    ctx.anonDocker = mkdtempSync(join(tmpdir(), "slim-ecr-anon-docker-"));
  }
};

const destinationDigest = (ctx: Context, reference: string): string => {
  ensureAnon(ctx);
  const result = ctx.run(["regctl", "image", "digest", reference], {
    env: { REGCTL_CONFIG: ctx.anonRegctl, DOCKER_CONFIG: ctx.anonDocker },
  });
  return result.ok ? result.stdout.trim() : "";
};

const manifestHead = (ctx: Context, reference: string): string => {
  const result = ctx.run(["regctl", "manifest", "head", reference]);
  return result.ok ? result.stdout.trim() : "";
};

const loadNatives = (path: string | undefined, version: string): ReadonlyArray<NativeArtifact> | undefined => {
  if (path === undefined || path.trim() === "") return undefined;
  return parseNatives(JSON.parse(readFileSync(path, "utf8")), version);
};

const payloadFor = (
  ctx: Context,
  service: string,
  version: string,
  digest: string,
  natives?: ReadonlyArray<NativeArtifact>,
): unknown =>
  renderPayload({
    eventType: ctx.eventType,
    service,
    version,
    source: `${ctx.sourcePrefix}/${service}:${version}`,
    digest,
    destination: `${ctx.destPrefix}/${service}:${version}`,
    natives: natives ?? loadNatives(ctx.nativesFile, version),
  });

const collectSourceNatives = (ctx: Context, service: string, version: string): ReadonlyArray<NativeArtifact> => {
  const rows: NativeArtifact[] = [];
  for (const target of NATIVE_TARGETS) {
    const tag = `${version}-native-${target}`;
    const digest = manifestHead(ctx, `${ctx.sourcePrefix}/${service}:${tag}`);
    if (DIGEST_PATTERN.test(digest)) rows.push({ tag, digest });
  }
  return rows;
};

const nativesOutOfSync = (
  ctx: Context,
  service: string,
  natives: ReadonlyArray<NativeArtifact>,
  quiet = false,
): boolean => {
  let drift = false;
  for (const { tag, digest } of natives) {
    const live = destinationDigest(ctx, `${ctx.destPrefix}/${service}:${tag}`);
    if (live === digest) {
      if (!quiet) log(`in sync native: ${service} ${tag} (${digest})`);
    } else {
      if (!quiet) log(`out of sync native: ${service} ${tag} (expected ${digest}, got ${live || "none"})`);
      drift = true;
    }
  }
  return drift;
};

const verifyRelease = async (ctx: Context, service: string, version: string, digest: string): Promise<void> => {
  ensureAnon(ctx);
  const destinationRef = `${ctx.destPrefix}/${service}:${version}`;
  const deadline = Date.now() + ctx.timeoutSec * 1000;
  for (;;) {
    const live = destinationDigest(ctx, destinationRef);
    if (live === digest) {
      log(`verified ${destinationRef}@${digest}`);
      return;
    }
    if (Date.now() >= deadline)
      fail(
        `destination did not match within ${ctx.timeoutSec}s: ${destinationRef} (expected ${digest}, got ${live || "none"})`,
      );
    log(`waiting for ${destinationRef} (expected ${digest}, got ${live || "none"})`);
    await Bun.sleep(ctx.pollSec * 1000);
  }
};

const requestRelease = async (
  ctx: Context,
  service: string,
  version: string,
  digest: string,
  natives?: ReadonlyArray<NativeArtifact>,
): Promise<void> => {
  if (ctx.token === undefined || ctx.token.trim() === "")
    fail("MIRROR_DISPATCH_TOKEN is required to send repository_dispatch");
  log(`requesting mirror of ${ctx.sourcePrefix}/${service}:${version}@${digest} via ${ctx.dispatchRepo}`);
  const sent = ctx.run(["gh", "api", `repos/${ctx.dispatchRepo}/dispatches`, "--input", "-"], {
    env: { GH_TOKEN: ctx.token },
    stdin: `${JSON.stringify(payloadFor(ctx, service, version, digest, natives), null, 2)}\n`,
  });
  if (!sent.ok) fail(`repository_dispatch to ${ctx.dispatchRepo} failed`);
  await verifyRelease(ctx, service, version, digest);
};

const waitNatives = async (
  ctx: Context,
  service: string,
  natives: ReadonlyArray<NativeArtifact>,
): Promise<boolean> => {
  const deadline = Date.now() + ctx.timeoutSec * 1000;
  while (nativesOutOfSync(ctx, service, natives, true)) {
    if (Date.now() >= deadline) {
      nativesOutOfSync(ctx, service, natives);
      return false;
    }
    log(`waiting for ${service} natives`);
    await Bun.sleep(ctx.pollSec * 1000);
  }
  nativesOutOfSync(ctx, service, natives);
  return true;
};

const listReleasePages = (ctx: Context): unknown => {
  const result = ctx.run([
    "gh",
    "api",
    "--paginate",
    "--slurp",
    `repos/${ctx.githubRepository}/releases?per_page=100`,
  ]);
  if (!result.ok) fail(result.stderr.trim() || "failed to list GitHub releases");
  return JSON.parse(result.stdout);
};

const syncReleases = async (ctx: Context, request: boolean): Promise<void> => {
  const releases = publishedReleases(ctx.config, listReleasePages(ctx));
  if (releases.length === 0) fail("no published releases found");
  let imageDrift = 0;
  let nativeDriftCount = 0;
  let skipped = 0;
  for (const { service, version } of releases) {
    const source = `${ctx.sourcePrefix}/${service}:${version}`;
    const sourceDigest = manifestHead(ctx, source);
    if (!DIGEST_PATTERN.test(sourceDigest)) {
      log(`skipped: ${service} ${version} has no source image at ${source}`);
      skipped += 1;
      continue;
    }
    const live = destinationDigest(ctx, `${ctx.destPrefix}/${service}:${version}`);
    const natives = collectSourceNatives(ctx, service, version);
    let nativeDrift = nativesOutOfSync(ctx, service, natives);
    if (live === sourceDigest && !nativeDrift) {
      log(`in sync: ${service} ${version} (${sourceDigest})`);
      continue;
    }
    if (live !== sourceDigest) log(`out of sync: ${service} ${version} (expected ${sourceDigest}, got ${live || "none"})`);
    else log(`out of sync: ${service} ${version} natives`);
    if (!request) {
      if (live !== sourceDigest) imageDrift += 1;
      if (nativeDrift) nativeDriftCount += 1;
      continue;
    }
    await requestRelease(ctx, service, version, sourceDigest, natives);
    nativeDrift = ctx.requireNatives
      ? !(await waitNatives(ctx, service, natives))
      : nativesOutOfSync(ctx, service, natives);
    if (nativeDrift) nativeDriftCount += 1;
  }
  if (skipped > 0) log(`skipped ${skipped} release(s) without a source image`);
  if (nativeDriftCount > 0) log(`${nativeDriftCount} release(s) have native tag drift`);
  if (imageDrift > 0) fail(`${imageDrift} release image(s) are missing from ${ctx.destPrefix}`);
  if (nativeDriftCount > 0 && ctx.requireNatives)
    fail(`${nativeDriftCount} release(s) have native tags missing from ${ctx.destPrefix}`);
  log(`all published release images are mirrored to ${ctx.destPrefix}`);
};

const makeContext = (run: RunCommand): Context => {
  const root = join(import.meta.dir, "..");
  const configFile = envString("SERVICE_RELEASE_CONFIG", join(root, ".github/service-release-sources.json"));
  return {
    config: loadReleaseConfig(configFile),
    dispatchRepo: envString("MIRROR_DISPATCH_REPO", "supabase/cli"),
    eventType: envString("MIRROR_EVENT_TYPE", "mirror-slim-image"),
    sourcePrefix: envString("SOURCE_IMAGE_PREFIX", "ghcr.io/supabase/cli"),
    destPrefix: envString("ECR_MIRROR_PREFIX", "public.ecr.aws/supabase/cli"),
    timeoutSec: envNumber("ECR_MIRROR_TIMEOUT", 900),
    pollSec: envNumber("ECR_MIRROR_POLL_INTERVAL", 30),
    requireNatives: envString("ECR_MIRROR_REQUIRE_NATIVES", "0") === "1",
    nativesFile: process.env["NATIVE_ARTIFACTS_FILE"],
    token: process.env["MIRROR_DISPATCH_TOKEN"],
    githubRepository: envString("GITHUB_REPOSITORY", "supabase/slim-services"),
    run,
    anonRegctl: "",
    anonDocker: "",
  };
};

export const main = async (argv: ReadonlyArray<string>, run: RunCommand = defaultSpawn): Promise<void> => {
  if (argv[0] === "-h" || argv[0] === "--help") {
    console.log(usage);
    return;
  }
  const command = argv[0];
  if (command === undefined) throw new ScriptError(usage, 2);
  if (command === "published-digest") {
    if (argv.length !== 2) throw new ScriptError(usage, 2);
    console.log(publishedDigest(argv[1] ?? ""));
    return;
  }
  const ctx = makeContext(run);
  if (command === "destination-repo") {
    if (argv.length !== 2) throw new ScriptError(usage, 2);
    const service = argv[1] ?? "";
    if (ctx.config.services[service] === undefined)
      throw new ScriptError(`unknown release service: ${service}`);
    console.log(`${ctx.destPrefix}/${service}`);
    return;
  }
  if (command === "payload") {
    if (argv.length !== 4) throw new ScriptError(usage, 2);
    const service = argv[1] ?? "";
    const version = argv[2] ?? "";
    const digest = argv[3] ?? "";
    validateRelease(ctx.config, service, version);
    validateDigest(digest);
    console.log(JSON.stringify(payloadFor(ctx, service, version, digest), null, 2));
    return;
  }
  if (command === "request") {
    if (argv.length !== 4) throw new ScriptError(usage, 2);
    const service = argv[1] ?? "";
    const version = argv[2] ?? "";
    const digest = argv[3] ?? "";
    validateRelease(ctx.config, service, version);
    validateDigest(digest);
    await requestRelease(ctx, service, version, digest);
    return;
  }
  if (command === "verify") {
    if (argv.length !== 4) throw new ScriptError(usage, 2);
    const service = argv[1] ?? "";
    const version = argv[2] ?? "";
    const digest = argv[3] ?? "";
    validateRelease(ctx.config, service, version);
    validateDigest(digest);
    await verifyRelease(ctx, service, version, digest);
    return;
  }
  if (command === "sync") {
    let request = false;
    const rest = argv.slice(1);
    if (rest[0] === "--request") {
      request = true;
      rest.shift();
    }
    if (rest.length !== 0) throw new ScriptError(usage, 2);
    await syncReleases(ctx, request);
    return;
  }
  throw new ScriptError(usage, 2);
};

if (import.meta.main) {
  try {
    await main(process.argv.slice(2));
  } catch (cause) {
    const error = cause instanceof ScriptError ? cause : new ScriptError(String(cause));
    if (error.exitCode === 2) console.error(error.message);
    else console.error(`[slim] ERROR: ${error.message}`);
    process.exit(error.exitCode);
  }
}
