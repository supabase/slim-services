# Supabase Slim Services

Experimental slim runtime artifacts and Docker images for Supabase services.

This repo asks a simple question:

> How small can each Supabase service image be if we package only the runtime
> files it actually needs?

The answer, for the current Linux ARM64 pass, is promising: the full set of
services drops from **1753.4 MiB** of upstream ARM64 images to **455.7 MiB** of
current slim images, a reduction of **1297.7 MiB / 74.0%**.

## Project Goals

This project has two long-term goals:

1. Figure out how to package each Supabase service as a self-contained archive
   or executable for macOS and Linux, as small as we can make it while still
   being reliable and smoke-testable.
2. Use those artifacts to produce the smallest practical Docker images, then
   upstream the maintainable build and packaging improvements back to each
   service repository.

The Docker images are the first delivery target because they immediately help
local development and CI. The deeper goal is portable, minimal service runtime
artifacts that can be reused both inside and outside containers.

## Why This Exists

Supabase local development and CI pull a lot of service images. Large images
cost time, bandwidth, cache space, and iteration speed. The goal here is to
produce smaller local/CI-oriented service images while keeping upstream service
source trees read-only and preserving a clear validation path.

The approach is intentionally service-by-service:

- Build or extract a minimal runtime artifact.
- Remove sourcemaps, debug files, caches, docs, tests, and other non-runtime
  debris.
- Copy only required binaries, release files, assets, and runtime libraries.
- Use the smallest viable final base: `scratch` first, then Distroless, then
  Alpine only when it is clearly the right fit.
- Smoke-test the artifact-backed image and the final slim image.

## Current Results

| Service | Version | Upstream ARM64 | Current slim | Reduction | Base | Report |
|---|---:|---:|---:|---:|---|---|
| PostgREST | `v14.10` | `126.0 MiB` | `21.2 MiB` | `83.2%` | `scratch` | [report](services/postgrest/REPORT.md) |
| Studio | `2026.04.27-sha-4afbe9c` | `294.2 MiB` | `128.4 MiB` | `56.4%` | Distroless Node 22 Debian 13 | [report](services/studio/REPORT.md) |
| Edge Runtime | `v1.73.15` | `360.6 MiB` | `60.8 MiB` | `83.1%` | Distroless base Debian 13 | [report](services/edge-runtime/REPORT.md) |
| Analytics | `v1.39.2` | `257.0 MiB` | `89.4 MiB` | `65.2%` | Distroless cc Debian 13 | [report](services/analytics/REPORT.md) |
| Realtime | `v2.87.0` | `122.8 MiB` | `24.0 MiB` | `80.5%` | Distroless cc Debian 13 | [report](services/realtime/REPORT.md) |
| Pooler | `v2.9.2` | `287.1 MiB`* | `24.3 MiB` | `91.5%`* | Distroless cc Debian 13 | [report](services/pooler/REPORT.md) |
| PgMeta | `v0.96.4` | `94.3 MiB` | `52.1 MiB` | `44.8%` | Distroless Node 20 Debian 13 | [report](services/pgmeta/REPORT.md) |
| Storage | `v1.55.3` | `211.4 MiB` | `55.5 MiB` | `73.7%` | Distroless Node 24 Debian 13 | [report](services/storage/REPORT.md) |

`*` Pooler upstream comparison uses `supabase/supavisor:2.7.4`, because
`supabase/supavisor:2.9.2` was not published on Docker Hub during this pass.

See [SLIM_IMAGES_REPORT.md](SLIM_IMAGES_REPORT.md) for the global summary.
Each service report is self-contained for distribution to the owning team.

## Repository Layout

```text
.
├── scripts/                  Shared artifact, image, measure, and smoke helpers
├── services/<service>/        Per-service recipes, Dockerfiles, smoke tests, reports
├── sources/<service>/         Upstream source repositories as pinned submodules
├── artifacts/                 Generated rootfs/archive outputs, gitignored
└── SLIM_IMAGES_REPORT.md      Global summary and cross-service lessons
```

The `sources/` directory is treated as read-only. Any local build changes,
runtime wrappers, shims, or packaging helpers belong under `services/<service>/`
or shared scripts in this repo.

## Artifact Contract

Every backend writes the same layout:

```text
artifacts/<service>/<version>/linux-<arch>/
├── rootfs/
├── <service>.tar.gz
└── manifest.json
```

The manifest records source ref, selected base image, entrypoint, smoke command,
artifact size, and image size when measured.

## Build Backends

Each service has a `services/<service>/recipe.env` file. The dispatcher reads
`ARTIFACT_BACKEND` and chooses one of:

- `docker-source`: build from the pinned source submodule with
  `services/<service>/Dockerfile.artifact`.
- `nix`: build from a configured Nix flake/package and copy declared runtime
  outputs into the artifact rootfs.
- `image`: extract selected paths from a published image as a fallback or
  comparison path.

The final `Dockerfile.slim` files are artifact-only: they copy a prepared
`rootfs/` into the smallest proven runtime base.

## Quick Start

Clone with submodules:

```bash
git clone --recursive git@github.com:supabase/slim-services.git
cd slim-services
```

Or, after a normal clone:

```bash
git submodule update --init --recursive
```

Build one service artifact:

```bash
scripts/build-artifact.sh storage v1.55.3
```

Build a slim image from that artifact:

```bash
scripts/build-image-from-artifact.sh \
  storage \
  artifacts/storage/v1.55.3/linux-arm64/rootfs \
  local/storage:slim-v1.55.3-arm64
```

Run the service smoke test:

```bash
scripts/smoke.sh storage --image local/storage:slim-v1.55.3-arm64
```

Or smoke an artifact rootfs directly, which first builds a temporary image:

```bash
scripts/smoke.sh storage --artifact artifacts/storage/v1.55.3/linux-arm64/rootfs
```

## Common Commands

Build the selected backend for a service:

```bash
scripts/build-artifact.sh <service> [version]
```

Build a final slim image:

```bash
scripts/build-image-from-artifact.sh <service> <artifact-rootfs> [image-tag]
```

Run smoke tests:

```bash
scripts/smoke.sh <service> --image <image-tag>
scripts/smoke.sh <service> --artifact <artifact-rootfs>
```

Measure rootfs/archive/image sizes:

```bash
scripts/measure-artifact.sh <artifact-rootfs> [archive] [image-tag]
```

## Service Reports

- [PostgREST](services/postgrest/REPORT.md): stable ARM64 dynamic bundle in
  `scratch`; static upstream artifact path validated for a future stable
  release.
- [Studio](services/studio/REPORT.md): Next.js standalone image kept at phase 1;
  a local-dev-only Sharp tradeoff could save more, but is not adopted.
- [Edge Runtime](services/edge-runtime/REPORT.md): adopted Nix/native artifact
  pruning and ONNX runtime cleanup.
- [Analytics](services/analytics/REPORT.md): adopted native stripping,
  sourcemap-gzip pruning, curl removal, and base-library dedupe.
- [Realtime](services/realtime/REPORT.md): adopted local/CI launcher and
  base-library dedupe; Alpine experiment rejected.
- [Pooler](services/pooler/REPORT.md): adopted POSIX launcher, native stripping,
  and base-library dedupe.
- [PgMeta](services/pgmeta/REPORT.md): Rolldown and Sentryless experiments
  worked but were too small to adopt.
- [Storage](services/storage/REPORT.md): adopted Rolldown emitted-JS bundle with
  minification and no dependency shims.

## Design Principles

- Upstream submodules stay read-only.
- Prefer `scratch` when the artifact proves it can run there.
- Prefer Distroless Debian 13 for glibc services.
- Avoid Alpine unless musl is validated and wins.
- Keep optimizations maintainable; do not carry a phase 2 variant for a tiny
  compressed gain.
- Record rejected experiments. Knowing what is not worth doing is part of the
  asset.

## Status

This repo is ready for team review and CI hardening. The first optimization
pass is complete; the next phase is to turn the current scripts and smoke tests
into repeatable CI jobs, then broaden smoke coverage where teams want narrower
local-development profiles.
