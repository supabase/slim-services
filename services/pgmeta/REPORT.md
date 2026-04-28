# PgMeta Slim Image Report

Self-contained report for the Postgres Meta Linux ARM64 slim-image work.

Last updated: 2026-04-28

## Summary

PgMeta remains at the phase 1 slim image. We tested a Rolldown bundle path and a
local/CI Sentryless profile. Both smoke-tested, but each saved only `2.4 MiB`
compressed, below the threshold for maintaining a separate phase 2 artifact.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `supabase/postgres-meta:v0.96.4` | `94.3 MiB` compressed |
| Current slim image, `local/pgmeta:slim-v0.96.4-arm64` | `52.1 MiB` compressed |
| Reduction vs upstream | `42.2 MiB / 44.8%` |
| Best tested experimental image | `49.7 MiB` compressed |
| Experimental gain | `2.4 MiB / 4.6%` |
| Accepted phase 2 delta | `0.0 MiB / 0.0%` |

## Build Contract

- Current backend: source submodule build.
- Source ref: `v0.96.4`.
- Upstream image: `supabase/postgres-meta:v0.96.4`.
- Runtime base: `gcr.io/distroless/nodejs20-debian13:nonroot`.
- Smoke test: `/health` returns `200`.
- `sources/pgmeta` is read-only.

## Current Slim Image

PgMeta keeps the upstream TypeScript build path:

```text
tsc -p tsconfig.json && cpy 'src/lib/sql/*.sql' dist/lib/sql
```

The runtime artifact uses production dependency pruning and the Debian 13
Distroless Node 20 base.

Important phase 1 fixes:

- Replaced a fragile direct-source Rolldown route with upstream TypeScript
  build output.
- Pruned production `node_modules` while preserving real runtime directories.
- Updated the global prune script to avoid deleting `yaml/dist/doc`, which is a
  runtime module despite its name.

## Rolldown Experiment

What was tested:

- Direct source-entry Rolldown failed on upstream type-only re-export patterns
  such as `PostgresMetaOk`, because those exports are types in TypeScript but
  become missing runtime exports to the bundler.
- App-local `npm install rolldown` perturbed the dependency tree enough to make
  upstream TypeScript compilation fail.
- Installing Rolldown globally in the builder image avoided dependency tree
  perturbation.
- Bundling emitted `dist/server/server.js` worked and smoked successfully.

Result:

| Variant | Compressed Docker image |
|---|---:|
| Current pgmeta slim image | `52.1 MiB` |
| Naive emitted-JS Rolldown image | `49.7 MiB` |
| Gain | `2.4 MiB` |

Decision: not adopted. The `2.4 MiB` gain is below the maintenance threshold.

## Sentryless Runtime Experiment

What was tested:

- Added no-op ESM shims for `@sentry/node` and `@sentry/profiling-node`.
- Temporarily removed `@sentry`, `@sentry-internal`, `@opentelemetry`,
  `import-in-the-middle`, and `require-in-the-middle` after upstream TypeScript
  build and production prune.
- Copied the no-op shims back into `node_modules` so existing built imports
  continued to resolve.

Result:

| Artifact / image | Size |
|---|---:|
| Current compressed Docker image | `52.1 MiB` |
| Sentryless compressed Docker image | `49.7 MiB` |
| Sentryless artifact archive | `5.8 MiB` |
| Sentryless rootfs | `32.9 MiB` |
| Sentryless local image virtual size | `155.8 MiB` |

Smoke passed with
`scripts/smoke.sh pgmeta --image local/pgmeta:slim-v0.96.4-sentryless-arm64`.

Decision: not adopted. The compressed image gain was only `2.4 MiB`.

## Decision

Keep PgMeta at phase 1. The tested phase 2 paths work, but the compressed
savings are too small for the added variant/overlay maintenance.

## Follow-Up

- Revisit bundling only if it can remove a larger runtime surface.
- Audit production dependencies for packages unused by broader runtime paths.
- Consider local-dev dependency shims only if the expected compressed gain is
  above the threshold.
