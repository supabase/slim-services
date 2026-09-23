/**
 * Mirror published slim images to AWS ECR Public and native triplets to ECR
 * Public and the public S3 bucket, through the mirror workflow hosted in the
 * dispatch repository (supabase/cli by default). Each destination is checked
 * independently, so one failing mirror never hides or blocks another. Always
 * dispatch: an unchanged image digest must not skip the request, because
 * native tags may have moved. Never prune untagged manifests; already-shipped
 * CLIs still pin those digests.
 *
 * Run: `bun scripts/ecr-mirror.ts payload|published-digest|destination-repo|request|verify|sync …`
 */

import { appendFileSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { CHECKSUM_TYPE } from "./publish-native-oci.ts";
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
  bun scripts/ecr-mirror.ts sync [--request] [SERVICE ...]

Mirror published slim images to AWS ECR Public and native triplets to ECR
Public and the public S3 bucket, through the mirror workflow hosted in the
dispatch repository (supabase/cli by default). Always dispatch: an unchanged
image digest must not skip the request, because native tags may have moved.
Never prune untagged manifests; already-shipped CLIs still pin those digests.

request dispatches one release and waits for its image on ECR Public and its
natives on S3 within one shared timeout, reporting each destination.

sync audits every published GitHub Release, or only the named services. A
release whose GHCR image is missing is skipped and counted, not fatal. With
--request it dispatches every out-of-sync release first and then waits for
all of them within one shared timeout, so an unreachable destination cannot
stall the backfill of the others. Image drift on ECR Public and native drift
on S3 fail the audit. Native tag drift on ECR Public is reported but only
fails the audit (and is only waited for) when ECR_MIRROR_REQUIRE_NATIVES=1;
the cli handler copies those natives best-effort.`;

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
  readonly s3BaseUrl: string;
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

type MirrorKind = "image" | "native" | "s3-native";

type MirrorCheck = {
  readonly kind: MirrorKind;
  readonly name: string;
  readonly expected: string;
  readonly live: () => string;
};

const KIND_LABEL: Readonly<Record<MirrorKind, string>> = {
  image: "",
  native: " native",
  "s3-native": " S3 native",
};

const checksumLayerDigest = (ctx: Context, service: string, digest: string): string => {
  const result = ctx.run([
    "regctl",
    "manifest",
    "get",
    `${ctx.sourcePrefix}/${service}@${digest}`,
    "--format",
    "raw-body",
  ]);
  if (!result.ok) return "";
  try {
    const parsed: unknown = JSON.parse(result.stdout);
    const layers = typeof parsed === "object" && parsed !== null ? (parsed as { layers?: unknown }).layers : undefined;
    if (!Array.isArray(layers)) return "";
    const layer = layers.find(
      (entry) => typeof entry === "object" && entry !== null && (entry as { mediaType?: unknown }).mediaType === CHECKSUM_TYPE,
    ) as { digest?: unknown } | undefined;
    return typeof layer?.digest === "string" && DIGEST_PATTERN.test(layer.digest) ? layer.digest : "";
  } catch {
    return "";
  }
};

const objectDigest = (ctx: Context, url: string): string => {
  const result = ctx.run(["curl", "-fsSL", "--retry", "2", url]);
  if (!result.ok) return "";
  return `sha256:${new Bun.CryptoHasher("sha256").update(result.stdout).digest("hex")}`;
};

const releaseChecks = (
  ctx: Context,
  service: string,
  version: string,
  digest: string,
  natives: ReadonlyArray<NativeArtifact>,
): ReadonlyArray<MirrorCheck> => {
  const image = `${ctx.destPrefix}/${service}:${version}`;
  const checks: MirrorCheck[] = [
    { kind: "image", name: `${service} ${version}`, expected: digest, live: () => destinationDigest(ctx, image) },
  ];
  const tagRe = nativeTagPattern(version);
  for (const { tag, digest: nativeDigest } of natives) {
    const reference = `${ctx.destPrefix}/${service}:${tag}`;
    checks.push({
      kind: "native",
      name: `${service} ${tag}`,
      expected: nativeDigest,
      live: () => destinationDigest(ctx, reference),
    });
    const target = tagRe.exec(tag)?.[1];
    if (target === undefined) continue;
    const url = `${ctx.s3BaseUrl}/${service}/${version}/${service}-${version}-${target}.SHA256SUMS`;
    checks.push({
      kind: "s3-native",
      name: `${service} ${version} ${target}`,
      expected: checksumLayerDigest(ctx, service, nativeDigest),
      live: () => objectDigest(ctx, url),
    });
  }
  return checks;
};

const inSync = (check: MirrorCheck): boolean => {
  const live = check.live();
  const label = KIND_LABEL[check.kind];
  if (check.expected !== "" && live === check.expected) {
    log(`in sync${label}: ${check.name} (${check.expected})`);
    return true;
  }
  log(`out of sync${label}: ${check.name} (expected ${check.expected || "unknown"}, got ${live || "none"})`);
  return false;
};

// Native ECR copies are best-effort on the cli side, so they are only waited
// on and enforced under ECR_MIRROR_REQUIRE_NATIVES=1.
const required = (ctx: Context, check: MirrorCheck): boolean => check.kind !== "native" || ctx.requireNatives;

/**
 * Polls every required check against one shared deadline, so a mirror that
 * never converges (for example an ECR Public outage) costs one timeout rather
 * than one per release and never holds back the other destinations.
 */
const settle = async (ctx: Context, checks: ReadonlyArray<MirrorCheck>): Promise<ReadonlyArray<MirrorCheck>> => {
  const deadline = Date.now() + ctx.timeoutSec * 1000;
  let waiting = checks.filter((check) => required(ctx, check));
  for (;;) {
    waiting = waiting.filter((check) => check.expected !== "" && check.live() !== check.expected);
    if (waiting.length === 0 || Date.now() >= deadline) break;
    log(`waiting for ${waiting.map((check) => `${check.name}${KIND_LABEL[check.kind]}`).join(", ")}`);
    await Bun.sleep(ctx.pollSec * 1000);
  }
  return checks.filter((check) => !inSync(check));
};

const dispatch = (
  ctx: Context,
  service: string,
  version: string,
  digest: string,
  natives?: ReadonlyArray<NativeArtifact>,
): boolean => {
  if (ctx.token === undefined || ctx.token.trim() === "")
    fail("MIRROR_DISPATCH_TOKEN is required to send repository_dispatch");
  log(`requesting mirror of ${ctx.sourcePrefix}/${service}:${version}@${digest} via ${ctx.dispatchRepo}`);
  const sent = ctx.run(["gh", "api", `repos/${ctx.dispatchRepo}/dispatches`, "--input", "-"], {
    env: { GH_TOKEN: ctx.token },
    stdin: `${JSON.stringify(payloadFor(ctx, service, version, digest, natives), null, 2)}\n`,
  });
  if (!sent.ok) log(`repository_dispatch to ${ctx.dispatchRepo} failed for ${service} ${version}`);
  return sent.ok;
};

const DRIFT_MESSAGES: Readonly<Record<MirrorKind, (count: number, ctx: Context) => string>> = {
  image: (count, ctx) => `${count} release image(s) are missing from ${ctx.destPrefix}`,
  native: (count, ctx) => `${count} native tag(s) missing from ${ctx.destPrefix}`,
  "s3-native": (count, ctx) => `${count} native artifact(s) missing from ${ctx.s3BaseUrl}`,
};

const driftFailures = (ctx: Context, stale: ReadonlyArray<MirrorCheck>): string[] => {
  const failures: string[] = [];
  for (const kind of ["image", "native", "s3-native"] as const) {
    const count = stale.filter((check) => check.kind === kind).length;
    if (count === 0) continue;
    const message = DRIFT_MESSAGES[kind](count, ctx);
    log(message);
    if (kind !== "native" || ctx.requireNatives) failures.push(message);
  }
  return failures;
};

const writeGithubOutput = (key: string, value: string): void => {
  const path = process.env["GITHUB_OUTPUT"];
  if (path !== undefined && path.trim() !== "") appendFileSync(path, `${key}=${value}\n`);
};

const requestRelease = async (ctx: Context, service: string, version: string, digest: string): Promise<void> => {
  const natives = loadNatives(ctx.nativesFile, version);
  if (!dispatch(ctx, service, version, digest, natives)) fail(`repository_dispatch to ${ctx.dispatchRepo} failed`);
  const stale = await settle(ctx, releaseChecks(ctx, service, version, digest, natives ?? []));
  if (!stale.some((check) => check.kind === "image")) writeGithubOutput("mirrored", "true");
  const failures = driftFailures(ctx, stale);
  if (failures.length > 0) fail(failures.join("; "));
};

const verifyRelease = async (ctx: Context, service: string, version: string, digest: string): Promise<void> => {
  const stale = await settle(ctx, releaseChecks(ctx, service, version, digest, []));
  if (stale.length > 0)
    fail(`destination did not match within ${ctx.timeoutSec}s: ${ctx.destPrefix}/${service}:${version}`);
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

const syncReleases = async (ctx: Context, request: boolean, services: ReadonlyArray<string>): Promise<void> => {
  for (const service of services)
    if (ctx.config.services[service] === undefined) fail(`unknown release service: ${service}`);
  const releases = publishedReleases(ctx.config, listReleasePages(ctx)).filter(
    ({ service }) => services.length === 0 || services.includes(service),
  );
  if (releases.length === 0) fail("no published releases found");
  const drifted: MirrorCheck[] = [];
  let skipped = 0;
  let undelivered = 0;
  for (const { service, version } of releases) {
    const source = `${ctx.sourcePrefix}/${service}:${version}`;
    const sourceDigest = manifestHead(ctx, source);
    if (!DIGEST_PATTERN.test(sourceDigest)) {
      log(`skipped: ${service} ${version} has no source image at ${source}`);
      skipped += 1;
      continue;
    }
    const natives = collectSourceNatives(ctx, service, version);
    const checks = releaseChecks(ctx, service, version, sourceDigest, natives);
    const releaseDrift = checks.filter((check) => !inSync(check));
    if (releaseDrift.length === 0) continue;
    if (request && !dispatch(ctx, service, version, sourceDigest, natives)) undelivered += 1;
    drifted.push(...releaseDrift);
  }
  const stale = request ? await settle(ctx, drifted) : drifted;
  if (skipped > 0) log(`skipped ${skipped} release(s) without a source image`);
  const failures = driftFailures(ctx, stale);
  if (undelivered > 0) failures.push(`${undelivered} mirror request(s) could not be dispatched to ${ctx.dispatchRepo}`);
  if (failures.length > 0) fail(failures.join("; "));
  log(`all published releases are mirrored to ${ctx.destPrefix} and ${ctx.s3BaseUrl}`);
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
    s3BaseUrl: envString("S3_MIRROR_BASE_URL", "https://supabase-cli-artifacts.s3.us-east-1.amazonaws.com"),
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
    const rest = argv.slice(1);
    const request = rest[0] === "--request";
    if (request) rest.shift();
    if (rest.some((service) => service.startsWith("-"))) throw new ScriptError(usage, 2);
    await syncReleases(ctx, request, rest);
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
