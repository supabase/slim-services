# Storage Slim Image Report

Self-contained report for the Storage API Linux ARM64 slim-image work.

Last updated: 2026-04-28

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
- Source ref: `v1.55.3`.
- Upstream image: `supabase/storage-api:v1.55.3`.
- Runtime base: `gcr.io/distroless/nodejs24-debian13:nonroot`.
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

- Adopted `services/storage/Dockerfile.artifact.rolldown`.
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

- Built using `services/storage/Dockerfile.artifact.rolldown` with
  `LOCAL_RUNTIME_PRUNE=0` and `ROLLDOWN_MINIFY=1`.
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
