# Studio Slim Image Report

Self-contained report for the Studio Linux ARM64 slim-image work.

Last updated: 2026-04-28

## Summary

Studio remains at the phase 1 slim image. We revisited phase 2 multiple times:
safe Next.js runtime pruning, package/dependency analysis, dev-dependency
auditing, and a second image composition pass. The only candidate above the
`10 MiB` compressed threshold requires a deliberate local-dev contract that
removes/degrades Sharp image optimization. We have not adopted that tradeoff.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `supabase/studio:2026.04.27-sha-4afbe9c` | `294.2 MiB` compressed |
| Current slim image, `local/studio:slim-2026.04.27-sha-4afbe9c-arm64` | `128.4 MiB` compressed |
| Reduction vs upstream | `165.8 MiB / 56.4%` |
| Phase 2 accepted delta | `0.0 MiB / 0.0%` |

## Build Contract

- Current backend: source submodule build.
- Source ref: `4afbe9c2b2ee5b0985b104def6850b3062328492`.
- Runtime base: `gcr.io/distroless/nodejs22-debian13:nonroot`.
- Build output: upstream Next.js standalone output.
- Smoke test: `/api/platform/profile` returns `200`.
- `sources/studio` is read-only; local changes belong in `services/studio/overlay`.

## Current Slim Image

The artifact copies:

- Next standalone server output.
- `.next/static`.
- `public` assets.
- `services/studio/overlay/docker-entrypoint.mjs`.

The packaging step removes `.nft.json` tracing manifests and sourcemaps. The
artifact already avoids broad dev-only debris such as tests, caches, TypeScript
build info, and package-manager logs.

## Final Image Composition

| Image component | Approx compressed size | Notes |
|---|---:|---|
| Distroless Node 22 runtime | `41.4 MiB` | Mostly the Node binary layer. |
| Other Debian/distroless base layers | `10 MiB` | glibc, OpenSSL, libstdc++, tzdata, CA certs, and base metadata. |
| Studio artifact layer | `76.6 MiB` | Next standalone output, static assets, public assets, and traced runtime packages. |
| Total | `128.4 MiB` | Local `docker save | gzip -9` measurement. |

## Artifact Composition

| Artifact path | Approx compressed size | Raw size | Needed? |
|---|---:|---:|---|
| `.next/static/chunks` | `36.9 MiB` | `144 MiB` | Yes. Browser client payload; cannot be deleted wholesale. |
| `node_modules/.pnpm` | `25.8 MiB` | `136 MiB` | Yes. Next standalone traced runtime closure. |
| `public` | `9.5 MiB` | `19 MiB` | Mostly visible UI assets. |
| `.next/server` | `5.4 MiB` | `24 MiB` | Yes. Server and route output. |
| `.next/static/media` | `2.3 MiB` | `3.4 MiB` | Static media emitted by build. |

## Notable Packages And Assets

| Path / package | Raw size | Approx compressed contribution | Notes |
|---|---:|---:|---|
| `public/img` | `8.2 MiB` | `6.6 MiB` | Visible UI images. Biggest file is `vault.png` at `2.8 MiB`. |
| `public/monaco-editor` | `9.5 MiB` | `2.2 MiB` | Needed by self-host/local build because `NEXT_PUBLIC_IS_PLATFORM=false` loads Monaco locally. |
| `@img/sharp-libvips-linux-arm64` | `16 MiB` | `7.1 MiB` | Needed for efficient Next image optimization. |
| `stripe-experiment-sync` | `26 MiB` | `1.9 MiB` | Needed by Stripe Sync integration route/UI; shimmable for local-dev only. |
| `braintrust` | `12 MiB` | `1.9 MiB` | Needed by AI tracing imports and feedback routes; shimmable for local-dev only. |
| `next` | `16 MiB` | `2.6 MiB` | Required Next runtime. |
| `@shikijs/langs` | `8.0 MiB` | `1.2 MiB` | Syntax-highlighting language data; not a first-order compressed win. |

## Phase 2 Experiments

### Conservative Runtime Prune

Tested removing sourcemaps, trace manifests, TypeScript build info,
declaration files, debug logs, build caches, and coverage output.

| Artifact / image | Size |
|---|---:|
| Baseline artifact archive | `80.0 MiB` |
| Pruned artifact archive | `79.7 MiB` |
| Baseline final image | `435.1 MiB` local virtual size |
| Pruned final image | `431.6 MiB` local virtual size |

Smoke passed, but the gain was too small to adopt.

### Next Bundle And Dependency Audit

Largest traced runtime packages included:

- `stripe-experiment-sync@1.0.31`: `26.2 MiB` raw.
- `@img/sharp-libvips-linux-arm64@1.2.4`: `16.0 MiB` raw.
- `next@16.2.3`: `13.2 MiB` raw.
- `braintrust@3.9.0`: `8.8-12 MiB` raw depending measurement path.
- `@shikijs/langs@3.13.0`: `7.5-8.0 MiB` raw.

No broad dev-only leak like `vitest` was found in the standalone runtime.
Studio declares `61` direct `devDependencies`; `54` are absent from the runtime
closure. The obvious test/build stack is absent.

### Local-Dev Profile Probe

| Probe | Rootfs | Local image virtual size | Compressed Docker image | Result |
|---|---:|---:|---:|---|
| Phase 1 baseline | `328 MiB` | `435.1 MiB` | `128.4 MiB` | Accepted current image. |
| Shim Braintrust/Stripe, keep Sharp | `276 MiB` | `396.6 MiB` | `124.8 MiB` | Saves `3.6 MiB`; too small. |
| Shim Braintrust/Stripe, remove Sharp/libvips | `260 MiB` | `380.0 MiB` | `117.5 MiB` | Saves `10.9 MiB`; smoke passed, but image optimization is degraded. |

Endpoint checks for the no-Sharp probe:

- `/api/platform/profile`: `200`.
- GET `/api/integrations/stripe-sync`: `405`, matching baseline after shims.
- GET `/api/ai/feedback/rate`: `405`, matching baseline after shims.
- `/_next/image?url=%2Fimg%2Fvault.png&w=384&q=75`: `200`, but response grew
  from a `14 KiB` optimized image to the original `2.8 MiB` payload.

## Decision

- Keep Studio at the phase 1 image for now.
- Do not adopt Braintrust/Stripe shims alone; the compressed gain is only
  `3.6 MiB`.
- Do not remove Sharp/libvips unless the Studio team explicitly accepts a
  local-dev image profile with disabled or degraded Next image optimization.
- The larger future prize is route-aware pruning of `.next/static/chunks`, but
  that needs a clear local-dev route contract and broader smoke coverage.

## Follow-Up

- Decide whether a local-dev Studio image may disable image optimization.
- If yes, implement that as an explicit overlay/profile instead of silently
  relying on Sharp absence.
- Consider image recompression for `public/img`, especially `vault.png`.
- Broaden Studio smoke coverage before route-aware client chunk pruning.

## Footprint Pass 3 (runtime profile, 2026-07)

- Bumped `sources/studio` to `20290c71` (`supabase/studio:2026.06.29-sha-20290c7`,
  the CLI-pinned image; studio releases are cut from monorepo commits, not tags).
- Added `runtime.env` baked as image ENV (overridable):
  `NODE_OPTIONS=--max-old-space-size=192 --max-semi-space-size=2`,
  `NEXT_TELEMETRY_DISABLED=1`.
- The Sharp local-dev profile remains not adopted (unchanged decision); studio
  is the top CLI-level candidate for a shared singleton across parallel stacks.

| Metric | Value |
|---|---:|
| Image compressed (`docker save \| gzip -9`) | `136.3 MiB` |
| Steady-state RSS (idle, after /api/platform/profile) | `201.4 MiB` |
| Idle CPU | `0.00 %` |

Note: the compressed image grew from `128.4 MiB` (2026.04.27) because upstream
studio itself grew over two months of releases; the slim techniques are
unchanged (Next.js standalone output on distroless nodejs22).
