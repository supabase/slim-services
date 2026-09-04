# Supabase Slim Services

Experimental slim runtime artifacts and Docker images for Supabase services.

This repo asks a simple question, on three axes:

> How small can each Supabase service be — in **image size**, **memory**, and
> **CPU** — if we package only the runtime files it actually needs and ship it
> with a low-footprint runtime profile?

<!-- generated:release-summary:begin -->
For the latest published Linux ARM64 release set (10 services), upstream images
total **2044.1 MiB** compressed; the slim set totals **562.6 MiB** (**72.5%**
smaller — exact numbers below). Every published service also ships measured
steady-state RSS and idle-CPU numbers, and a minimal core stack (postgres +
auth + postgrest) idles at roughly **66 MiB of RSS per stack** with near-zero
idle CPU.
<!-- generated:release-summary:end -->

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
sampled by each service's smoke test (`docker stats`). The slim image and
runtime values below come from the `linux-arm64` manifest attached to each
service's latest release in this repository. Upstream ARM64 sizes are measured
from the matching upstream image tag; Pooler retains its documented comparison
override because its exact release tag is unavailable on Docker Hub.

<!-- generated:results:begin -->
| Service | Version | Upstream ARM64 | Published slim | Reduction | Idle RSS | Idle CPU | Sources |
|---|---:|---:|---:|---:|---:|---:|---|
| Postgres | `17.6.1.166` (all PG17 extensions, minimal preload) | `349.8 MiB` | `132.7 MiB` | `62.1%` | `47.6 MiB` | `0.01%` | [release](https://github.com/supabase/slim-services/releases/tag/postgres-17.6.1.166) · [report](services/postgres/REPORT.md) |
| PostgREST | `v16.2` | `6.2 MiB` | `5.9 MiB` | `4.2%` | `8.7 MiB` | `0.09%` | [release](https://github.com/supabase/slim-services/releases/tag/postgrest-v16.2) · [report](services/postgrest/REPORT.md) |
| Auth | `v2.196.0` | `26.5 MiB` | `11.5 MiB` | `56.6%` | `9.4 MiB` | `0.00%` | [release](https://github.com/supabase/slim-services/releases/tag/auth-v2.196.0) · [report](services/auth/REPORT.md) |
| Realtime | `v2.130.0` | `116.9 MiB` | `27.3 MiB` | `76.7%` | `180.2 MiB` | `0.20%` | [release](https://github.com/supabase/slim-services/releases/tag/realtime-v2.130.0) · [report](services/realtime/REPORT.md) |
| Storage | `v1.71.0` | `223.8 MiB` | `51.0 MiB` | `77.2%` | `215.6 MiB` | `0.01%` | [release](https://github.com/supabase/slim-services/releases/tag/storage-v1.71.0) · [report](services/storage/REPORT.md) |
| Edge Runtime | `v1.74.3` (no-AI) | `360.6 MiB` | `52.7 MiB` | `85.4%` | `18.1 MiB` | `0.01%` | [release](https://github.com/supabase/slim-services/releases/tag/edge-runtime-v1.74.3) · [report](services/edge-runtime/REPORT.md) |
| Studio | `2026.08.24-sha-8ec45b2` | `306.5 MiB` | `128.2 MiB` | `58.2%` | `205.9 MiB` | `0.00%` | [release](https://github.com/supabase/slim-services/releases/tag/studio-2026.08.24-sha-8ec45b2) · [report](services/studio/REPORT.md) |
| Analytics | `v1.50.6` | `261.4 MiB` | `58.5 MiB` | `77.6%` | `497.5 MiB` | `0.31%` | [release](https://github.com/supabase/slim-services/releases/tag/analytics-v1.50.6) · [report](services/analytics/REPORT.md) |
| PgMeta | `v0.98.0` | `103.0 MiB` | `56.1 MiB` | `45.5%` | `108.4 MiB` | `0.36%` | [release](https://github.com/supabase/slim-services/releases/tag/pgmeta-v0.98.0) · [report](services/pgmeta/REPORT.md) |
| Pooler | `v2.9.12` | `289.4 MiB`* | `38.7 MiB` | `86.6%`* | `165.0 MiB` | `0.11%` | [release](https://github.com/supabase/slim-services/releases/tag/pooler-v2.9.12) · [report](services/pooler/REPORT.md) |

`*` Upstream comparison uses `UPSTREAM_COMPARE_IMAGE` from the recipe (the exact tag is not published on Docker Hub), so the percentage is directional.
<!-- generated:results:end -->

Studio is now in the native automatic release pipeline. It remains omitted
from this release-backed snapshot until the first native Studio release
publishes its measured manifests.

Postgres is native-first like everything else: the image is derived from the
portable artifact, which ships every extension the upstream PG17 image
supports (timescaledb/plv8 are PG17-incompatible upstream). Extensions are
installed but not enabled — only the minimal `shared_preload_libraries` set
is on by default, so the footprint numbers are unaffected; the few
preload-gated extensions (pgaudit, pg_stat_monitor, pg_tle) take a config
opt-in.

### Host-Native Artifacts

Every service in the release workflow ships a self-contained, relocatable
`tar.zst` archive per target ([HOST_NATIVE_PLAN.md](HOST_NATIVE_PLAN.md)) that
the CLI can download to `~/.supabase/bin/<service>/<version>/` and run without
Docker — on macOS and on Linux (only the glibc family is assumed from a
Linux host; each Node service bundles its upstream-selected runtime inside the archive — the
wrapper prefers `node/bin/node`, no external runtime, `runtime_requires` is
null). The Linux Docker images are derived from these same artifacts. The
table below shows the `darwin-arm64` values from the manifest attached to the
same published release used above. Idle RSS and Idle CPU are sampled from the
artifact running as a real host process with `runtime.env` applied (`ps`-based,
recorded in the manifest). Local rebuilds can preview table changes with
`scripts/update-results-tables.sh --host-native-only` (darwin) or `--merge`;
published release manifests remain the source of truth for this snapshot.

Linux archives share a measured, CI-gated Ubuntu 22.04/glibc 2.35 floor (see
CI_MATRIX.md); macOS archives require macOS 14+. Artifacts that consume host
glibc (currently edge-runtime and Mailpit) are checked against that floor.
Postgres, PostgREST (dynamic Linux builds), imgproxy, the BEAM trio, and the
Node services (storage, pgmeta, and Studio) carry a matched loader+glibc
runtime and are proven in Ubuntu 22.04, so their execution does not depend on
the host glibc version. Auth is statically linked and Vector uses musl. The
manifest records the applicable floor as `os_floor`.

<!-- generated:host-native:begin -->
| Service | Version | Archive | rootfs | Idle RSS | Idle CPU | Portable | Sources |
|---|---:|---:|---:|---:|---:|---|---|
| Postgres | `17.6.1.166` | `103.0 MiB` | `662.7 MiB` | `70.5 MiB` | `0.00%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/postgres-17.6.1.166) · [report](services/postgres/REPORT.md) |
| PostgREST | `v16.2` | `12.5 MiB` | `78.1 MiB` | `55.7 MiB` | `0.07%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/postgrest-v16.2) · [report](services/postgrest/REPORT.md) |
| Auth | `v2.196.0` | `9.5 MiB` | `33.9 MiB` | `29.9 MiB` | `0.00%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/auth-v2.196.0) · [report](services/auth/REPORT.md) |
| Realtime | `v2.130.0` | `12.0 MiB` | `48.5 MiB` | `205.2 MiB` | `0.43%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/realtime-v2.130.0) · [report](services/realtime/REPORT.md) |
| Storage | `v1.71.0` | `36.1 MiB` | `143.6 MiB` | `288.4 MiB` | `0.03%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/storage-v1.71.0) · [report](services/storage/REPORT.md) |
| Edge Runtime | `v1.74.3` | `39.9 MiB` | `161.4 MiB` | `56.8 MiB` | `0.00%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/edge-runtime-v1.74.3) · [report](services/edge-runtime/REPORT.md) |
| Studio | `2026.08.24-sha-8ec45b2` | `75.9 MiB` | `463.3 MiB` | `317.9 MiB` | `0.00%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/studio-2026.08.24-sha-8ec45b2) · [report](services/studio/REPORT.md) |
| Analytics | `v1.50.6` | `33.4 MiB` | `140.6 MiB` | `517.2 MiB` | `0.30%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/analytics-v1.50.6) · [report](services/analytics/REPORT.md) |
| PgMeta | `v0.98.0` | `36.6 MiB` | `169.9 MiB` | `150.2 MiB` | `0.17%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/pgmeta-v0.98.0) · [report](services/pgmeta/REPORT.md) |
| Pooler | `v2.9.12` | `23.5 MiB` | `52.5 MiB` | `216.0 MiB` | `0.10%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/pooler-v2.9.12) · [report](services/pooler/REPORT.md) |
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
  145 MiB, so 25 parallel stacks cost ~3.5 GiB. Analytics (~500 MiB) and
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
  cross-compiles (auth) and Node bundles (storage, pgmeta, Studio; these must
  run on a host matching the target because package managers resolve platform
  packages).
- `docker-image`: run `Dockerfile.artifact` rooted at a published upstream
  image (`FROM $SOURCE_IMAGE`, pinned by `SOURCE_IMAGE_DIGEST`) — used when
  pruning the published image is the practical path (postgres).
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
TARGET_OS=darwin ARCH=arm64 scripts/build-artifact.sh auth v2.194.0
TARGET_OS=linux ARCH=arm64 scripts/build-artifact.sh realtime v2.121.2
```

Build the derived slim image from a Linux artifact:

```bash
scripts/build-image-from-artifact.sh \
  realtime \
  artifacts/realtime/v2.121.2/linux-arm64/rootfs \
  local/realtime:slim-v2.121.2-arm64
```

Run the service smoke test against the image:

```bash
scripts/smoke.sh realtime --image local/realtime:slim-v2.121.2-arm64
```

Or smoke an artifact rootfs. On a matching darwin host this runs the service
as a real host process (no Docker for the service); Linux artifacts smoke
through a temporary image by default, or as a host process on a matching
Linux host with `SLIM_DIRECT_LINUX_ARTIFACT_SMOKE=1`:

```bash
scripts/smoke.sh auth --artifact artifacts/auth/v2.194.0/darwin-arm64/rootfs
SLIM_DIRECT_LINUX_ARTIFACT_SMOKE=1 \
  scripts/smoke.sh realtime --artifact artifacts/realtime/v2.121.2/linux-arm64/rootfs
```

Hosts without Docker (e.g. macOS CI runners) can run the harness postgres as
a host process too: `SLIM_SMOKE_HOST_POSTGRES=1`.

Run the full CI-style build for one service and matrix cell (build, portable
audit, smoke, archive + SHA256SUMS; Linux additionally derives and smokes the
Docker image):

```bash
TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh edge-runtime v1.74.2
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh realtime v2.121.2
```

## Publishing Service Releases

`.github/workflows/service-release.yml` publishes one upstream service release
at a time. It verifies that the requested version is an exact, stable,
published release tag in the configured upstream repository, checks out only
that tag (never a branch such as `main`), and builds the complete
`linux-amd64`, `linux-arm64`, and `darwin-arm64` artifact matrix. Publication
for a derived-image service begins only after every artifact and Docker image
smoke passes. Mirror services follow a separate gate: the workflow verifies
the pinned upstream source, copies the exact OCI index and referrers, verifies
the destination digest/referrer set, and requires anonymous destination
resolution plus pull/service smoke before the GitHub release is published and
the release is considered qualified. Public package visibility still requires
post-publication confirmation.

- Portable archives, platform manifests, and a combined `SHA256SUMS` are
  attached to the GitHub release `<service>-<version>`.
- The exact smoked Linux images are published as a multi-platform image at
  `ghcr.io/supabase/cli/<service>:<version>`.

Run a release manually with:

```bash
gh workflow run service-release.yml \
  -f service=auth \
  -f version=v2.194.0 \
  -f force=false
```

`.github/workflows/poll-service-releases.yml` polls stable upstream releases
and Docker Hub tags hourly and dispatches independent service-release runs for
the oldest eligible version tag that does not yet have a corresponding GitHub
release here. Each polled service declares a `release_floor` at the first
version published by this repository; the poller reconciles every matching
stable upstream release from that adoption boundary onward. It dispatches at
most three versions per service per poll while keeping no more than twelve
release workflows active across the repository. Active versions and versions
attempted unsuccessfully within the previous six hours are skipped without
blocking later missing versions. The cooldown starts from GitHub's final
workflow update; a successful workflow whose release is not visible gets a
ten-minute publication grace instead. Failures therefore remain retryable
without creating gaps or unbounded hourly fan-out. All configured polled
services are enabled. PostgreSQL release eligibility comes from published
`supabase/postgres` Docker Hub tags, and each native source checkout is pinned
to the one Git commit recorded by that image's provenance. Its policy accepts
only plain `17.x.x.NNN` releases with a three-digit AMI suffix; PostgreSQL 15,
OrioleDB, architecture-specific, and other suffixed release tags are ignored.

Mailpit and Vector are the non-polled upstream-archive services. Imgproxy is a
non-polled source-built Nix/external-source service. Their release workflows
accept an explicit version, resolve the versionless descriptor against GitHub
and the independent OCI repository at plan time, and publish one run-scoped
snapshot plus digest for every build, mirror, and release consumer. The recipe
receives that verified snapshot through `UPSTREAM_ASSETS_FILE`; no checked-in
per-version policy is used. They are intentionally absent from the generated
size/runtime tables until first publication and the anonymous pull gates
complete. See the [Mailpit report](services/mailpit/REPORT.md), [Vector
report](services/vector/REPORT.md), and [imgproxy report](services/imgproxy/REPORT.md)
for historical input digests, normalized layouts, smoke coverage, and
publication checklists.

After a successful release run, `.github/workflows/release-results.yml`
downloads the newest published manifest set for every service, regenerates the
two README tables, and merges the result through a short-lived docs pull
request. The shared concurrency group coalesces simultaneous service releases,
and the hourly reconciliation schedule repairs any missed or failed refresh.
It uses the repository's GitHub App credentials because the organization does
not allow the built-in Actions token to create pull requests.

The release workflow rechecks the upstream release policy independently, so a
manual dispatch cannot publish `main`, another branch, a draft/prerelease, or
an unsupported tag. A newly triggered build can still fail safely when a
service's version-specific dependency hashes need to be refreshed; no release
or image is published unless every build and smoke test passes.

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
  including PostGIS/pgroonga/wrappers), low-memory conf overlay, and Docker-tag
  release polling with provenance-pinned source checkouts.
- [PostgREST](services/postgrest/REPORT.md): stable ARM64 dynamic bundle in
  `scratch`; static upstream artifact path validated for a future stable
  release.
- [Studio](services/studio/REPORT.md): target-native Next/TanStack-aware build,
  bundled upstream-selected Node runtime, artifact-derived slim image, and
  Docker-tag release polling with provenance verification.
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
- [PgMeta](services/pgmeta/REPORT.md): upstream TypeScript runtime with a
  bundled upstream-selected Node runtime; obsolete experimental variants are
  removed.
- [Storage](services/storage/REPORT.md): adopted Rolldown emitted-JS bundle with
  minification and no dependency shims.
- [Auth](services/auth/REPORT.md): static Go executable runs from `scratch`;
  phase 2 repeats phase 1 because further binary-level experiments are not
  worth carrying.
- [Mailpit](services/mailpit/REPORT.md): verified upstream native archives and
  an exact OCI image mirror; publication and anonymous-pull evidence remain
  release gates before generated tables are updated.
- [Vector](services/vector/REPORT.md): verified upstream native archives and
  an exact `timberio/vector:0.53.0-alpine` OCI image mirror; native release,
  anonymous-pull evidence, and later CLI integration remain open gates.
- [Imgproxy](services/imgproxy/REPORT.md): source-built portable Nix artifact
  with libvips codec coverage and an exact `ghcr.io/imgproxy/imgproxy` OCI
  image mirror; native release and anonymous-pull evidence remain release gates.

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
[HOST_NATIVE_PLAN.md](HOST_NATIVE_PLAN.md)). The release workflow has completed
the full `darwin-arm64`, `linux-arm64`, and `linux-amd64` build-and-smoke matrix
for all nine published services, attaching the portable archives to GitHub
Releases and pushing the exact tested Linux images to GHCR. The legacy
`.github/workflows/service-artifacts.yml` remains for experiments and services
outside the release set. CLI-side integration (download/verify and
process-compose wiring) is the next step, tracked in
[SLIM_IMAGES_REPORT.md](SLIM_IMAGES_REPORT.md) § Remaining Work and the plan's
Phase 5 notes.

## Licensing

The packaging code in this repository is licensed under the [MIT License](LICENSE).
Built artifacts contain independently licensed upstream
software. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); each archive
also carries the license material collected from its dependency closure under
`share/licenses/` and is published with an SPDX SBOM.
