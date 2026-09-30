# Storage Slim Image Report

Self-contained report for the Storage API Linux ARM64 slim-image work.

Last updated: 2026-08-27

## Summary

Storage has an adopted phase 2 slim image. The current image keeps upstream
type-check/transpile behavior, then bundles the emitted runtime JavaScript with
Rolldown and minification. We intentionally did not adopt dependency shims for
telemetry/pprof because the extra gain was too small.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `supabase/storage-api:v1.55.3` | `211.4 MiB` compressed |
| Phase 1 slim image | `77.1 MiB` compressed |
| Current phase 2 slim image, `local/storage:slim-v1.55.3-arm64` | `55.5 MiB` compressed |
| Phase 2 gain vs phase 1 | `21.6 MiB / 28.0%` |
| Current reduction vs upstream | `155.9 MiB / 73.7%` |
| Phase 2 artifact archive | `3.9 MiB` |
| Phase 2 rootfs | `21.2 MiB` |
| Phase 2 local image virtual size | `170.2 MiB` |

## Build Contract

- Current backend: source submodule build.
- Source ref: `v1.62.6`.
- Upstream image: `supabase/storage-api:v1.62.6`.
- Runtime base: `gcr.io/distroless/base-debian13` (root, empty Config.User)
  plus the artifact's
  upstream-selected bundled Node runtime.
- Smoke test: `/status` returns `200`.
- `sources/storage` is read-only; bundling changes live in overlay files.

## Upstream Build Shape

Storage's upstream build is:

```text
tsc -noEmit && node ./build.js && resolve-tspaths
```

`build.js` uses esbuild to transpile TypeScript into many CommonJS files, but
does not bundle. This made Storage a good candidate for an emitted-JS bundling
pass.

## Phase 2 Changes

- Adopted the repo-owned Rolldown overlay in the target-native build.
- Kept upstream build as the type-check/transpile step.
- Bundled emitted `dist` JavaScript with Rolldown.
- Minified the Rolldown bundle.
- Kept Swagger static assets, small external runtime package set,
  `package.json`, and migrations.
- Moved to Debian 13 Distroless Node 24.
- Kept dependency graph unshimmed for maintainability.

## Variant Measurements

| Variant | Rootfs | Artifact archive | Compressed Docker image | Smoke |
|---|---:|---:|---:|---|
| Phase 1 upstream-build slim | about `230 MiB` | `28.6 MiB` | `77.1 MiB` | Pass |
| Telemetry/pprof prune only | `124.4 MiB` | `13.1 MiB` | `63.1 MiB` | Pass |
| Naive Rolldown | `40.2 MiB` | `5.6 MiB` | `57.2 MiB` | Pass |
| Rolldown plus minify, no shims | `21.2 MiB` | `3.9 MiB` | `55.5 MiB` | Pass |
| Rolldown plus local prune | `30.2 MiB` | `3.8 MiB` | `55.5 MiB` | Pass |
| Rolldown plus local prune and minify | `16.2 MiB` | `2.9 MiB` | `54.5 MiB` | Pass |

The adopted path is "Rolldown plus minify, no shims" because it captures the
large maintainable win. The local telemetry/pprof prune only saves another
`1.0 MiB` compressed after Rolldown minification, so it is not worth carrying.

## Validation

- Built through `services/storage/build-host.sh` with
  `ROLLDOWN_MINIFY=1`.
- Built final image with
  `scripts/build-image-from-artifact.sh storage artifacts/storage/v1.55.3/linux-arm64/rootfs local/storage:slim-v1.55.3-arm64`.
- Smoke passed with
  `IMAGE=local/storage:slim-v1.55.3-arm64 services/storage/smoke.sh`.
- `sources/storage` remained clean.

## Decision

Adopted. The compressed image gain is `21.6 MiB`, above the threshold, and the
accepted path avoids dependency shims or upstream source edits.

## Follow-Up

- Broaden smoke coverage beyond `/status` before further module replacement.
- Audit AWS, Smithy, Kubernetes, image-processing, vector/Iceberg dependency
  surfaces for optional local-development paths.
- Consider separate local-dev and full-runtime artifact profiles only after
  broader smoke coverage exists.

## Footprint Pass 3 (runtime profile, 2026-07)

- Bumped `sources/storage` to `v1.62.6` (latest release; CLI pins v1.61.9).
  Upstream removed the `patches/` directory; the rolldown artifact build no
  longer copies it.
- Broadened smoke beyond `/status`: bucket creation + object upload + object
  download round-trip against the file backend (`STORAGE_BACKEND=file`); the
  smoke grants `service_role` access to the migrated `storage` schema. This is
  the prerequisite coverage for any future module-level pruning of the AWS/
  Smithy/Iceberg dependency surfaces (still a follow-up).
- Added `runtime.env` baked as image ENV (overridable):
  `NODE_OPTIONS=--max-old-space-size=128 --max-semi-space-size=2`,
  `DATABASE_MAX_CONNECTIONS=2` (upstream default 20 — each held connection is
  a server-side postgres backend), `IMAGE_TRANSFORMATION_ENABLED=false`
  (imgproxy is not part of the slim local profile).

| Metric | Value |
|---|---:|
| Image compressed (`docker save \| gzip -9`) | `55.6 MiB` |
| Steady-state RSS (after object round-trip) | `211.5 MiB` |
| Idle CPU | `0.19 %` |

## Host-Native darwin-arm64 Artifact (2026-07)

Runtime decision (recorded in HOST_NATIVE_ARTIFACTS.md): bundle the
upstream-selected Node runtime per service. The artifact stays a Rolldown JS
bundle; a thin
`bin/storage` wrapper resolves the runtime (`SUPABASE_NODE` →
`../../node/bin/node` → `PATH`) and the manifest records no external runtime
requirement.

- `services/storage/build-host.sh` runs npm ci + upstream build + Rolldown
  directly on the target host. It derives Node from
  the upstream production Dockerfile and npm from upstream's exact
  `packageManager`, then uses the same pinned-Nix Node for the build and
  portable bundle. The one native module, `fs-xattr`, compiles for darwin
  during npm ci. Sharp is not a dependency at v1.62.6 (image transformation
  is imgproxy-based and off in the local profile).
- Smoke (host process, `runtime.env` applied): `/status` 200 plus the full
  bucket → upload → download round-trip on the file backend; re-run from an
  untarred archive in a scratch directory (relocatable); darwin audit clean.

| Metric | Value |
|---|---:|
| Archive (`storage-v1.62.6-darwin-arm64.tar.zst`) | `2.4 MiB` |
| rootfs | `18.7 MiB` |
| Steady-state RSS (host process, idle) | `187.2 MiB` |
| Idle CPU | `0.0 %` |

### Native-first convergence (2026-07)

`build-host.sh` builds the Linux artifacts on Linux hosts (a guard refuses
cross-builds: npm resolves platform packages — fs-xattr — for the machine it
runs on), and `Dockerfile.slim` derives the image from the artifact's `app/`
and `node/` trees on the generic distroless base (the `bin/storage` wrapper is
host-only). First Linux verification happens in CI
(`service-artifacts.yml`), by design.

## Image identity (docker.io interchange)

Start user and `/mnt` owner/mode are generated from the digest-pinned
`supabase/storage-api` image (IMAGE_CONTRACT.md). The image stays root,
ships `wget` for the CLI healthcheck, and pairwise smokes cover leftover
`/mnt` volumes plus an imgproxy-pin sidecar read.
- `IMAGE_TRANSFORMATION_ENABLED=false` is no longer baked in `runtime.env`:
  storage-api prefers that key over the legacy `ENABLE_IMAGE_TRANSFORMATION`
  the CLI sets, so the image-level `false` silently disabled imgproxy even
  when the stack enabled it. docker.io bakes no default either.
- Exec-form `HEALTHCHECK` (bundled node `fetch` of `/status`): Docker uses
  it when the stack omits `--health-cmd`, giving the CLI real readiness on a
  distroless image. The smoke waits for `docker inspect` to report
  `healthy`, not just a 200.

## Extended-attribute sidecar fallback (2026-09)

Storage's file backend keeps each object's content type, cache control and
multipart part etags in extended attributes. Docker Desktop's macOS file
sharing (VirtioFS and gRPC FUSE) rejects them with `ENOTSUP`, so every upload
into a bind-mounted directory failed there. OrbStack, Linux bind mounts and
APFS keep them.

Decision: the slim artifact replaces the bundled `fs-xattr` package with a
wrapper (`overlay/fs-xattr/index.js`) instead of patching upstream sources or
moving CLI uploads into engine volumes. `prepare-bundle-dist.mjs` moves the
real package to `node_modules/fs-xattr/native` and installs the wrapper in its
place; it fails the build if the real package's ESM entry changes or it
exports a function the wrapper does not.

- Native attributes stay authoritative. On `ENOTSUP` the wrapper stores the
  values in `<storage root>/.slim-xattr/<2 hex>/<sha256(relative path)>.json`,
  outside the object tree so empty-directory cleanup keeps working. Storage
  only creates its internal bucket (`GLOBAL_S3_BUCKET`) and `multiparts/` at
  the root; user buckets live below `<internal bucket>/<tenant>/`. The
  two-character shards keep each directory small.
- A native miss also reads the sidecar, so a directory written through Docker
  Desktop keeps its metadata when served from an engine with xattrs; native
  removal also clears the sidecar copy.
- Deletion does not go through `fs-xattr`, so deleted objects, superseded
  versions (every upload writes a new version path) and multipart parts leave
  orphaned sidecars, about one per upsert, move or delete. Each records its
  relative `path`, and a background sweep removes entries whose file is gone,
  plus `.tmp` files older than an hour. Uploads, copies and multipart parts
  write fresh versioned paths; the unversioned Iceberg S3 `PutObject` path can
  be rewritten, so a delete and re-upload racing the sweep can lose that
  object's metadata. A native set or remove also drops the sidecar copy, since
  multipart parts are rewritten in place.
- The sweep never blocks requests. The first pass starts 30 s after the
  process loads (every wake from idle sleep is a fresh container), and later
  passes repeat hourly while it lives. A pass processes one entry at a time
  with async I/O and pauses after every 50 entries for at least 100 ms, twice
  the batch time when the filesystem is slow. A `.sweep-cursor` records the
  last swept entry at every pause, so a pass cut short by idle sleep resumes
  there, even inside a large shard; a
  completed pass writes `.last-sweep` and is not repeated within the hour. A
  `.sweep-lock`, refreshed after every batch and stale after 2 minutes, keeps
  a second process from sweeping the same directory; a container stopped
  mid-pass leaves it behind, so the resume waits for it to expire. Unreadable entries are left alone.
  `SLIM_STORAGE_XATTR_SWEEP=immediate` skips the delay and interval for the
  smoke.
- A relative storage root is resolved against the working directory, which
  usually differs from Storage's own resolution, so the original `ENOTSUP`
  remains; the fallback needs an absolute root.
- Upstream `supabase/storage-api` reading a fallback directory serves
  `application/octet-stream` and `no-cache`.
- `SLIM_STORAGE_XATTR_SIDECAR=force` makes the wrapper act as if the filesystem
  had rejected every attribute; the image smoke uses it because CI runners'
  volumes support xattrs.

Drop the wrapper once every version at or above `release_floor` handles
`ENOTSUP` itself.
