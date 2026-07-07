# Supabase Slim Services

Experimental slim runtime artifacts and Docker images for Supabase services.

This repo asks a simple question, on three axes:

> How small can each Supabase service be — in **image size**, **memory**, and
> **CPU** — if we package only the runtime files it actually needs and ship it
> with a low-footprint runtime profile?

For the current Linux ARM64 pass (10 services, latest releases): upstream
images total ~**2.1 GiB** compressed; the slim set totals ~**765 MiB**
(~**65%** smaller — exact numbers in the generated table below). Every service
also ships measured steady-state RSS and idle-CPU numbers, and a minimal core
stack (postgres + auth + postgrest) idles at roughly **100 MiB of RSS per
stack** with near-zero idle CPU.

## Project Goals

This project has three long-term goals:

1. Figure out how to package each Supabase service as a self-contained archive
   or executable for macOS and Linux, as small as we can make it while still
   being reliable and smoke-testable.
2. Use those artifacts to produce the smallest practical Docker images, then
   upstream the maintainable build and packaging improvements back to each
   service repository.
3. Minimize each service's runtime footprint — steady-state memory and idle
   CPU — so many local stacks can run in parallel on one developer machine
   (the working target: ~25 stacks on a 32 GB laptop).

The Docker images are the first delivery target because they immediately help
local development and CI. The deeper goal is portable, minimal service runtime
artifacts that can be reused both inside and outside containers.

## Why This Exists

Supabase local development and CI pull a lot of service images. Large images
cost time, bandwidth, cache space, and iteration speed. The goal here is to
produce smaller local/CI-oriented service images while keeping upstream service
source trees read-only and preserving a clear validation path.

Disk is only half the story: image layers are stored once and shared by every
container, but **RSS and CPU multiply per running stack**. That is why each
service now also carries a runtime profile and measured runtime numbers — see
[Runtime Footprint](#runtime-footprint) below.

The approach is intentionally service-by-service:

- Build or extract a minimal runtime artifact.
- Remove sourcemaps, debug files, caches, docs, tests, and other non-runtime
  debris.
- Copy only required binaries, release files, assets, and runtime libraries.
- Use the smallest viable final base: `scratch` first, then Distroless, then
  Alpine only when it is clearly the right fit.
- Smoke-test the artifact-backed image and the final slim image.

## Current Results

Image sizes are gzip-compressed; Idle RSS and Idle CPU are steady-state values
sampled by each service's smoke test (`docker stats`, recorded per build in
`manifest.json`). The table below is generated — refresh it with
`scripts/update-results-tables.sh` after rebuilding services.

<!-- generated:results:begin -->
| Service | Version | Upstream ARM64 | Current slim | Reduction | Idle RSS | Idle CPU | Report |
|---|---:|---:|---:|---:|---:|---:|---|
| Postgres | `17.6.1.143` (all extensions) | `349.8 MiB` | `293.9 MiB` | `16.0%` | `66.1 MiB` | `0.01%` | [report](services/postgres/REPORT.md) |
| PostgREST | `v14.14` | `145.3 MiB` | `20.3 MiB` | `86.0%` | `29.4 MiB` | `0.13%` | [report](services/postgrest/REPORT.md) |
| Auth | `v2.192.0` | `25.8 MiB` | `11.2 MiB` | `56.6%` | `8.2 MiB` | `0.01%` | [report](services/auth/REPORT.md) |
| Realtime | `v2.112.6` | `114.7 MiB` | `28.4 MiB` | `75.2%` | `166.6 MiB` | `0.14%` | [report](services/realtime/REPORT.md) |
| Storage | `v1.62.6` | `223.5 MiB` | `55.6 MiB` | `75.1%` | `211.5 MiB` | `0.19%` | [report](services/storage/REPORT.md) |
| Edge Runtime | `v1.74.2` (no-AI) | `360.6 MiB` | `52.7 MiB` | `85.4%` | `14.7 MiB` | `0.04%` | [report](services/edge-runtime/REPORT.md) |
| Studio | `2026.06.29-sha-20290c7` | `304.7 MiB` | `136.3 MiB` | `55.3%` | `201.4 MiB` | `0.00%` | [report](services/studio/REPORT.md) |
| Analytics | `v1.46.0` | `258.9 MiB` | `89.7 MiB` | `65.3%` | `546.7 MiB` | `0.35%` | [report](services/analytics/REPORT.md) |
| PgMeta | `v0.96.6` | `94.2 MiB` | `52.7 MiB` | `44.1%` | `79.4 MiB` | `0.70%` | [report](services/pgmeta/REPORT.md) |
| Pooler | `v2.9.10` | `289.4 MiB`* | `24.3 MiB` | `91.6%`* | `155.6 MiB` | `0.18%` | [report](services/pooler/REPORT.md) |

`*` Upstream comparison uses `UPSTREAM_COMPARE_IMAGE` from the recipe (the exact tag is not published on Docker Hub), so the percentage is directional.
<!-- generated:results:end -->

Postgres is native-first like everything else: the image is derived from the
portable artifact, which ships every extension the upstream PG17 image
supports (timescaledb/plv8 are PG17-incompatible upstream). Extensions are
installed but not enabled — only the minimal `shared_preload_libraries` set
is on by default, so the footprint numbers are unaffected; the few
preload-gated extensions (pgaudit, pg_stat_monitor, pg_tle) take a config
opt-in.

### Host-Native Artifacts

Every Supabase-owned service ships a self-contained, relocatable `tar.zst`
archive per target ([HOST_NATIVE_PLAN.md](HOST_NATIVE_PLAN.md)) that the CLI
can download to `~/.supabase/bin/<service>/<version>/` and run without
Docker — on macOS and on Linux (only the glibc family is assumed from a
Linux host; the Node duo resolves the shared Node runtime recorded in the
manifest's `runtime_requires`). The Linux Docker images are derived from
these same artifacts. The table below shows the darwin-arm64 numbers; Idle
RSS and Idle CPU are sampled from the artifact running as a real host
process with `runtime.env` applied (`ps`-based, recorded in the darwin
`manifest.json`). Refresh with
`scripts/update-results-tables.sh --host-native-only` after darwin rebuilds.

<!-- generated:host-native:begin -->
| Service | Version | Archive | rootfs | Idle RSS | Idle CPU | Portable | Report |
|---|---:|---:|---:|---:|---:|---|---|
| Postgres | `17.6.1.143` | `30.4 MiB` | `110.2 MiB` | `34.0 MiB` | `0.00%` | yes | [report](services/postgres/REPORT.md) |
| PostgREST | `v14.14` | `12.6 MiB` | `83.5 MiB` | `80.1 MiB` | `0.00%` | yes | [report](services/postgrest/REPORT.md) |
| Auth | `v2.192.0` | `9.4 MiB` | `33.5 MiB` | `29.3 MiB` | `0.00%` | yes | [report](services/auth/REPORT.md) |
| Realtime | `v2.112.6` | `11.9 MiB` | `40.8 MiB` | `113.0 MiB` | `0.07%` | yes | [report](services/realtime/REPORT.md) |
| Storage | `v1.62.6` | `2.4 MiB` | `18.7 MiB` | `187.2 MiB` | `0.00%` | yes | [report](services/storage/REPORT.md) |
| Edge Runtime | `v1.74.2` | `39.9 MiB` | `161.2 MiB` | `57.9 MiB` | `0.00%` | yes | [report](services/edge-runtime/REPORT.md) |
| Analytics | `v1.46.0` | `33.3 MiB` | `137.9 MiB` | `523.0 MiB` | `0.00%` | yes | [report](services/analytics/REPORT.md) |
| PgMeta | `v0.96.6` | `3.7 MiB` | `48.2 MiB` | `125.6 MiB` | `0.27%` | yes | [report](services/pgmeta/REPORT.md) |
| Pooler | `v2.9.10` | `23.6 MiB` | `52.5 MiB` | `181.8 MiB` | `0.00%` | yes | [report](services/pooler/REPORT.md) |
<!-- generated:host-native:end -->

See [SLIM_IMAGES_REPORT.md](SLIM_IMAGES_REPORT.md) for the global summary.
Each service report is self-contained for distribution to the owning team.
For Nix-backed native services, see
[NIX_PORTABLE_ARTIFACT_PLAYBOOK.md](NIX_PORTABLE_ARTIFACT_PLAYBOOK.md) for the
reusable artifact-to-image pattern learned from Edge Runtime.
For CI target naming and commands, see [CI_MATRIX.md](CI_MATRIX.md).

## Runtime Footprint

Memory and CPU are first-class optimization targets, not just disk:

- **Runtime profiles** — each service has a `services/<service>/runtime.env`
  with low-footprint local-dev defaults, baked into the image as ENV and
  overridable at `docker run -e`. The same KEY=VALUE files are applied as
  process environment for host-native (no-Docker) runs — the host-process
  smokes do exactly that, mirroring the CLI. Highlights:
  - BEAM services (realtime, analytics, pooler): one scheduler and no
    scheduler busy-waiting (`+S 1:1 +sbwt none ...`) — idle CPU drops from
    several percent to ≤0.5%.
  - Node services (storage, studio, pgmeta): V8 heap caps
    (`--max-old-space-size`).
  - Go services (auth): `GOMEMLIMIT`, `GOGC`, `GOMAXPROCS`.
  - All DB clients: shrunk connection pools — every pooled connection holds a
    server-side postgres backend, so this also cuts postgres memory.
  - Postgres: a conf overlay (`shared_buffers=32MB`, `jit=off`, slowed idle
    ticks) via the stock `include_dir`; `wal_level=logical` untouched.
- **Measurement** — every smoke samples steady-state RSS and idle CPU
  (`record_runtime_metrics` via `docker stats` for containers,
  `record_host_runtime_metrics` via `ps` over the process tree for host
  processes — both in `scripts/smoke-lib.sh`) and records them under
  `runtime` in the artifact `manifest.json`, so regressions on these axes are
  visible per build, exactly like size.
- **The parallel-stacks view** — image layers are shared; RSS multiplies per
  stack. A minimal core stack (postgres + auth + postgrest) idles at roughly
  100 MiB, so 25 parallel stacks cost ~3 GiB. Analytics (~500 MiB) and
  Studio (~200 MiB) dominate when run per-stack and are disabled by default
  in the minimal stack.

## Repository Layout

```text
.
├── scripts/                  Shared artifact, image, measure, and smoke helpers
├── services/<service>/        Per-service recipes, Dockerfiles, smoke tests, reports
├── sources/<service>/         Upstream source repositories as pinned submodules
├── artifacts/                 Generated rootfs outputs and optional archives, gitignored
└── SLIM_IMAGES_REPORT.md      Global summary and cross-service lessons
```

The `sources/` directory is treated as read-only. Any local build changes,
runtime wrappers, shims, or packaging helpers belong under `services/<service>/`
or shared scripts in this repo.

## Artifact Contract

Every backend writes the same layout:

```text
artifacts/<service>/<version>/<platform>-<arch>/
├── rootfs/
├── <service>.tar.zst          Optional distribution archive
└── manifest.json
```

The expanded `rootfs/` is the canonical artifact for local smoke tests,
inspection, and Docker image assembly. Compressed archives are derived
distribution products and may be generated separately from an existing rootfs.

The manifest records source ref (or pinned image digest), selected base image,
entrypoint, smoke command, artifact size, image size, and — after an image
smoke — steady-state runtime metrics (`runtime.runtime_rss_mib`,
`runtime.idle_cpu_pct`).

## Build Backends

Native-first ([HOST_NATIVE_PLAN.md](HOST_NATIVE_PLAN.md)): for every
Supabase-owned service the portable, relocatable artifact is the single
source of truth on every target, and the Docker image is derived from that
same rootfs. Each service has a `services/<service>/recipe.env` file; the
dispatcher reads `ARTIFACT_BACKEND` and chooses one of:

- `nix`: build the portable rootfs from the repo-owned Nix package in
  `services/<service>/nix/` (applied over the read-only submodule via
  `NIX_PACKAGE_OVERLAY`). Used by the BEAM services (realtime, analytics,
  pooler) and edge-runtime. On Linux this runs local Nix when the host
  matches, or the service's `Dockerfile.artifact` nixos/nix builder
  otherwise (e.g. building Linux artifacts from macOS).
- `docker-source` with `ARTIFACT_SOURCE_BUILD="host"`: build with
  `services/<service>/build-host.sh` on the host toolchain — Go
  cross-compiles (auth) and Node bundles (storage, pgmeta; these must run on
  a host matching the target because npm resolves platform packages).
- `docker-image`: run `Dockerfile.artifact` rooted at a published upstream
  image (`FROM $SOURCE_IMAGE`, pinned by `SOURCE_IMAGE_DIGEST`) — used when
  pruning the published image is the practical path (postgres, studio).
- `image`: extract selected paths from a published image (postgrest — the
  extraction bundles the full ELF closure, so the result is still portable).

The final `Dockerfile.slim` files derive the image from the artifact: they
copy the prepared `rootfs/` into the smallest proven runtime base and add
only entry wiring (busybox/tini/CA-bundle stages where a shell entrypoint is
needed). Images are always assembled through `scripts/render-dockerfile.sh`,
which appends the `runtime.env` profile as ENV — never build
`Dockerfile.slim` directly or the runtime profile is silently skipped.

Portable archive builds share two hardening steps. For Nix-backed portable
artifacts, these checks should run inside the Nix package when practical; the
scripts remain available as shared helpers and external verification.

- `scripts/portable-darwin-fixup.sh` completes macOS dylib closures, rewrites
  Nix store install names, removes Nix store rpaths, strips local Mach-O
  symbols, and ad-hoc signs the result.
- `scripts/audit-portable-artifact.sh` fails artifacts that still have
  unresolved runtime dependencies or absolute Nix store references.

Archives prefer `zstd -19` and are produced by `scripts/archive-artifact.sh`
when a distributable bundle is needed. The script uses Nix's `zstd` package
automatically when `zstd` is not on PATH.

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

Build one service artifact (host-native for your machine):

```bash
TARGET_OS=darwin ARCH=arm64 scripts/build-artifact.sh auth v2.192.0
TARGET_OS=linux ARCH=arm64 scripts/build-artifact.sh realtime v2.112.6
```

Build the derived slim image from a Linux artifact:

```bash
scripts/build-image-from-artifact.sh \
  realtime \
  artifacts/realtime/v2.112.6/linux-arm64/rootfs \
  local/realtime:slim-v2.112.6-arm64
```

Run the service smoke test against the image:

```bash
scripts/smoke.sh realtime --image local/realtime:slim-v2.112.6-arm64
```

Or smoke an artifact rootfs. On a matching darwin host this runs the service
as a real host process (no Docker for the service); Linux artifacts smoke
through a temporary image by default, or as a host process on a matching
Linux host with `SLIM_DIRECT_LINUX_ARTIFACT_SMOKE=1`:

```bash
scripts/smoke.sh auth --artifact artifacts/auth/v2.192.0/darwin-arm64/rootfs
SLIM_DIRECT_LINUX_ARTIFACT_SMOKE=1 \
  scripts/smoke.sh realtime --artifact artifacts/realtime/v2.112.6/linux-arm64/rootfs
```

Hosts without Docker (e.g. macOS CI runners) can run the harness postgres as
a host process too: `SLIM_SMOKE_HOST_POSTGRES=1`.

Run the full CI-style build for one service and matrix cell (build, portable
audit, smoke, archive + SHA256SUMS; Linux additionally derives and smokes the
Docker image):

```bash
TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh edge-runtime v1.74.2
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh realtime v2.112.6
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

Create a distribution archive from an existing rootfs:

```bash
scripts/archive-artifact.sh <artifact-rootfs> [archive-prefix]
```

## Service Reports

- [Postgres](services/postgres/REPORT.md): Nix reference-graph prune of the
  published image; every supported extension kept (31 smoke-verified,
  including PostGIS/pgroonga/wrappers), low-memory conf overlay.
- [PostgREST](services/postgrest/REPORT.md): stable ARM64 dynamic bundle in
  `scratch`; static upstream artifact path validated for a future stable
  release.
- [Studio](services/studio/REPORT.md): Next.js standalone image kept at phase 1;
  a local-dev-only Sharp tradeoff could save more, but is not adopted.
- [Edge Runtime](services/edge-runtime/REPORT.md): adopted Nix/native artifact
  pruning; local-dev default excludes ONNX/OpenBLAS (`withAi = false`), the AI
  profile stays available upstream or via `withAi = true`.
- [Analytics](services/analytics/REPORT.md): adopted native stripping,
  sourcemap-gzip pruning, curl removal, and base-library dedupe.
- [Realtime](services/realtime/REPORT.md): adopted production-ready launcher
  aligned with upstream PR #1837 and base-library dedupe; Alpine experiment
  rejected.
- [Pooler](services/pooler/REPORT.md): adopted POSIX launcher, native stripping,
  and base-library dedupe.
- [PgMeta](services/pgmeta/REPORT.md): Rolldown and Sentryless experiments
  worked but were too small to adopt.
- [Storage](services/storage/REPORT.md): adopted Rolldown emitted-JS bundle with
  minification and no dependency shims.
- [Auth](services/auth/REPORT.md): static Go executable runs from `scratch`;
  phase 2 repeats phase 1 because further binary-level experiments are not
  worth carrying.

## Design Principles

- Upstream submodules stay read-only.
- Service-specific Nix changes live in this repo, not in `sources/`.
- Prefer `scratch` when the artifact proves it can run there.
- Prefer Distroless Debian 13 for glibc services.
- Avoid Alpine unless musl is validated and wins.
- Keep optimizations maintainable; do not carry a phase 2 variant for a tiny
  compressed gain.
- Record rejected experiments. Knowing what is not worth doing is part of the
  asset.

## Status

Four passes are complete: base-image/artifact slimming (pass 1),
service-specific pruning (pass 2), the runtime-footprint pass (pass 3 —
latest versions, postgres onboarding, `runtime.env` profiles, RSS/CPU
measurement in every smoke), and the host-native pass (pass 4 —
[HOST_NATIVE_PLAN.md](HOST_NATIVE_PLAN.md)): every Supabase-owned service
ships a self-contained, relocatable archive for `darwin-arm64` and
`linux-arm64`/`linux-amd64`, runnable with no Docker, with the Docker images
derived from those same artifacts. CI builds all of it via
`.github/workflows/service-artifacts.yml` (plus edge-runtime's own
workflow); the first full CI pass across all cells and the CLI-side
integration (download/verify, process-compose wiring) are the next steps,
tracked in [SLIM_IMAGES_REPORT.md](SLIM_IMAGES_REPORT.md) § Remaining Work
and the plan's Phase 5 notes.
