# Supabase Slim Services

Experimental slim runtime artifacts and Docker images for Supabase services.

This repo asks a simple question, on three axes:

> How small can each Supabase service be — in **image size**, **memory**, and
> **CPU** — if we package only the runtime files it actually needs and ship it
> with a low-footprint runtime profile?

<!-- generated:release-summary:begin -->
For the latest published Linux ARM64 release set (10 services), upstream images
total **2050.5 MiB** compressed; the slim set totals **549.3 MiB** (**73.2%**
smaller — exact numbers below). Every published service also has measured
steady-state RSS and idle-CPU numbers. These isolated service smoke
measurements do not establish complete Dockerless CLI-stack behavior or a
25-parallel-stack capacity result.
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
   CPU — and measure whether many local stacks can run in parallel on one
   developer machine (the working hypothesis is ~25 stacks on a 32 GB laptop).

The portable artifact is the common delivery. Derived Docker images serve
container-based local development and CI, while the CLI consumes the same
rootfs through native archives.

## Why This Exists

Supabase local development and CI pull a lot of service images. Large images
cost time, bandwidth, cache space, and iteration speed. The goal here is to
produce smaller local/CI-oriented service images while keeping upstream service
source trees read-only and preserving a clear validation path.

Disk is only half the story: image layers are stored once and shared by every
container, while runtime memory and CPU still matter for each running stack.
That is why service runtime profiles and measured runtime numbers are tracked
where available — see [Runtime Footprint](#runtime-footprint) below.

The approach is intentionally service-by-service:

- Build or extract a minimal runtime artifact.
- Remove sourcemaps, debug files, caches, docs, tests, and other non-runtime
  debris.
- Copy only required binaries, release files, assets, and runtime libraries.
- Use the smallest viable final base: `scratch` first, then Distroless, then
  Alpine only when it is clearly the right fit.
- Smoke-test the artifact-backed image and the final slim image.

## Current Results

Image sizes are gzip-compressed. Idle RSS and Idle CPU are steady-state values
sampled by each service's smoke test. Container values use the Docker `stats`
MemUsage sample; host values use process-tree RSS and an OS-dependent `ps`
`%cpu` average, so the samplers are not literal RSS equivalents or directly
comparable CPU samples. The slim image and runtime values below come from the
`linux-arm64` manifest attached to each published release in this repository.
Upstream ARM64 sizes are measured from the matching upstream image tag; Pooler
retains its documented comparison override because its exact release tag is
unavailable on Docker Hub.

<!-- generated:results:begin -->
| Service | Version | Upstream ARM64 | Published slim | Reduction | Idle RSS | Idle CPU | Sources |
|---|---:|---:|---:|---:|---:|---:|---|
| Postgres | `17.6.1.167` (all PostgreSQL extensions for the selected major, matching upstream preload configuration) | `349.9 MiB` | `108.1 MiB` | `69.1%` | `80.2 MiB` | `0.00%` | [release](https://github.com/supabase/slim-services/releases/tag/postgres-17.6.1.167) · [report](services/postgres/REPORT.md) |
| PostgREST | `v16.2` | `6.2 MiB` | `5.9 MiB` | `4.2%` | `9.1 MiB` | `0.07%` | [release](https://github.com/supabase/slim-services/releases/tag/postgrest-v16.2) · [report](services/postgrest/REPORT.md) |
| Auth | `v2.196.0` | `26.5 MiB` | `12.2 MiB` | `54.0%` | `8.5 MiB` | `0.43%` | [release](https://github.com/supabase/slim-services/releases/tag/auth-v2.196.0) · [report](services/auth/REPORT.md) |
| Realtime | `v2.132.0` | `116.9 MiB` | `27.3 MiB` | `76.7%` | `180.8 MiB` | `0.08%` | [release](https://github.com/supabase/slim-services/releases/tag/realtime-v2.132.0) · [report](services/realtime/REPORT.md) |
| Storage | `v1.72.4` | `224.1 MiB` | `52.4 MiB` | `76.6%` | `216.4 MiB` | `3.76%` | [release](https://github.com/supabase/slim-services/releases/tag/storage-v1.72.4) · [report](services/storage/REPORT.md) |
| Edge Runtime | `v1.75.0` (no-AI) | `360.9 MiB` | `53.2 MiB` | `85.3%` | `17.9 MiB` | `0.01%` | [release](https://github.com/supabase/slim-services/releases/tag/edge-runtime-v1.75.0) · [report](services/edge-runtime/REPORT.md) |
| Studio | `2026.08.31-sha-2c76bb3` | `306.5 MiB` | `130.9 MiB` | `57.3%` | `210.8 MiB` | `2.65%` | [release](https://github.com/supabase/slim-services/releases/tag/studio-2026.08.31-sha-2c76bb3) · [report](services/studio/REPORT.md) |
| Analytics | `v1.50.7` | `261.4 MiB` | `58.6 MiB` | `77.6%` | `507.4 MiB` | `0.24%` | [release](https://github.com/supabase/slim-services/releases/tag/analytics-v1.50.7) · [report](services/analytics/REPORT.md) |
| PgMeta | `v0.99.0` | `108.7 MiB` | `62.0 MiB` | `43.0%` | `117.5 MiB` | `3.84%` | [release](https://github.com/supabase/slim-services/releases/tag/pgmeta-v0.99.0) · [report](services/pgmeta/REPORT.md) |
| Pooler | `v2.9.12` | `289.4 MiB`* | `38.7 MiB` | `86.6%`* | `164.5 MiB` | `0.11%` | [release](https://github.com/supabase/slim-services/releases/tag/pooler-v2.9.12) · [report](services/pooler/REPORT.md) |

`*` Upstream comparison uses `UPSTREAM_COMPARE_IMAGE` from the recipe (the exact tag is not published on Docker Hub), so the percentage is directional.
<!-- generated:results:end -->

Postgres is native-first like everything else: the image is derived from the
portable artifact, which ships the extension set supported by the matching
upstream image for its selected major (PG15 includes TimescaleDB/plv8; PG17
omits those incompatible extensions). Its `shared_preload_libraries` policy
follows the matching `UPSTREAM_IMAGE`; the artifact does not replace upstream
preload behavior with a minimal list.

### Host-Native Artifacts

For a service with a published native manifest, the release workflow attaches a
self-contained, relocatable `tar.zst` archive per target
([HOST_NATIVE_ARTIFACTS.md](HOST_NATIVE_ARTIFACTS.md)) for the CLI to download
to `~/.supabase/bin/<service>/<version>/` and run without Docker. Linux images
for derived-image services use the same rootfs. The table below shows the
`darwin-arm64` values from the manifest attached to the same published release
used above. Host-process smokes apply `services/<service>/runtime.env` when
that file exists; the CLI integration must arrange the same profile. Local
rebuilds can preview table changes with
`scripts/update-results-tables.sh --host-native-only` (darwin) or `--merge`;
published release manifests remain the source of truth for this snapshot.

Linux archives share a measured, CI-gated Ubuntu 22.04/glibc 2.35 floor (see
CI_MATRIX.md); macOS archives require macOS 14+. Artifacts that consume host
glibc (currently edge-runtime and Mailpit) are checked against that floor.
Postgres, PostgREST (dynamic Linux builds), imgproxy, the BEAM trio, and the
Node services (storage, pgmeta, and Studio) carry a matched loader+glibc
runtime and are proven in Ubuntu 22.04, so their execution does not depend on
the host glibc version. Auth is statically linked and Vector uses musl. The
manifest records the host-applicable floor as `os_floor.floor`;
bundled-glibc artifacts report `null` there because their own loader/libc
define the runtime floor.

<!-- generated:host-native:begin -->
| Service | Version | Archive | rootfs | Idle RSS | Idle CPU | Portable | Sources |
|---|---:|---:|---:|---:|---:|---|---|
| Postgres | `17.6.1.167` | `102.0 MiB` | `441.7 MiB` | `72.9 MiB` | `0.00%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/postgres-17.6.1.167) · [report](services/postgres/REPORT.md) |
| PostgREST | `v16.2` | `12.5 MiB` | `78.1 MiB` | `55.7 MiB` | `0.03%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/postgrest-v16.2) · [report](services/postgrest/REPORT.md) |
| Auth | `v2.196.0` | `9.5 MiB` | `33.9 MiB` | `29.7 MiB` | `0.00%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/auth-v2.196.0) · [report](services/auth/REPORT.md) |
| Realtime | `v2.132.0` | `12.0 MiB` | `48.5 MiB` | `212.3 MiB` | `0.17%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/realtime-v2.132.0) · [report](services/realtime/REPORT.md) |
| Storage | `v1.72.4` | `36.8 MiB` | `149.7 MiB` | `291.0 MiB` | `0.03%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/storage-v1.72.4) · [report](services/storage/REPORT.md) |
| Edge Runtime | `v1.75.0` | `40.0 MiB` | `161.5 MiB` | `55.8 MiB` | `0.00%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/edge-runtime-v1.75.0) · [report](services/edge-runtime/REPORT.md) |
| Studio | `2026.08.31-sha-2c76bb3` | `76.6 MiB` | `471.7 MiB` | `322.8 MiB` | `0.00%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/studio-2026.08.31-sha-2c76bb3) · [report](services/studio/REPORT.md) |
| Analytics | `v1.50.7` | `33.4 MiB` | `140.7 MiB` | `489.6 MiB` | `0.27%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/analytics-v1.50.7) · [report](services/analytics/REPORT.md) |
| PgMeta | `v0.99.0` | `40.6 MiB` | `186.0 MiB` | `166.6 MiB` | `0.43%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/pgmeta-v0.99.0) · [report](services/pgmeta/REPORT.md) |
| Pooler | `v2.9.12` | `23.5 MiB` | `52.5 MiB` | `200.0 MiB` | `0.03%` | yes | [release](https://github.com/supabase/slim-services/releases/tag/pooler-v2.9.12) · [report](services/pooler/REPORT.md) |
<!-- generated:host-native:end -->

See [SLIM_IMAGES_REPORT.md](SLIM_IMAGES_REPORT.md) for the global summary.
Each service report is self-contained for distribution to the owning team.
For Nix-backed native services, see
[NIX_PORTABLE_ARTIFACT_PLAYBOOK.md](NIX_PORTABLE_ARTIFACT_PLAYBOOK.md) for the
reusable artifact-to-image pattern learned from Edge Runtime.
For CI target naming and commands, see [CI_MATRIX.md](CI_MATRIX.md).

## Runtime Footprint

Memory and CPU are first-class optimization targets, not just disk:

- **Runtime profiles** — where a service defines
  `services/<service>/runtime.env`, its low-footprint local-dev defaults are
  baked into the image as ENV and overridable at `docker run -e`. Host-process
  smokes apply the same KEY=VALUE file; the CLI integration must arrange it for
  native runs. Highlights:
  - BEAM services (realtime, analytics, pooler): one scheduler and no
    scheduler busy-waiting (`+S 1:1 +sbwt none ...`) — idle CPU drops from
    several percent to ≤0.5%.
  - Node services (storage, studio, pgmeta): V8 heap caps
    (`--max-old-space-size`).
  - Go services (auth): `GOMEMLIMIT`, `GOGC`, `GOMAXPROCS`.
  - All DB clients: shrunk connection pools — every pooled connection holds a
    server-side postgres backend, so this also cuts postgres memory.
- **Postgres configuration** — a conf overlay (`shared_buffers=32MB`,
  `jit=off`, slowed idle ticks) via the stock `include_dir`; `wal_level=logical`
  remains untouched.
- **Measurement** — smokes record steady-state runtime observations under
  `runtime` in the artifact `manifest.json`: containers use
  `record_runtime_metrics` via Docker `stats`, while host processes use
  `record_host_runtime_metrics` via `ps` (both in `scripts/smoke-lib.sh`).
  Host `%cpu` is an OS-dependent `ps` average, and these samplers do not
  produce literal RSS equivalents or directly comparable CPU samples.
- **Parallel stacks** — capacity remains unmeasured. Isolated service smokes do
  not model CLI orchestration, service dependencies, shared state, workload,
  or concurrent startup, so they do not prove a complete Dockerless CLI stack
  or the 25-stack target.

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
├── <service>-<version>-<platform>-<arch>.tar.zst
├── <service>-<version>-<platform>-<arch>.sbom.spdx.json
├── SHA256SUMS
└── manifest.json
```

The expanded `rootfs/` is the canonical artifact for local smoke tests,
inspection, and Docker image assembly. Compressed archives are derived
distribution products and may be generated separately from an existing rootfs.

The manifest records source ref (or pinned image digest), selected base image,
entrypoint, smoke command, portability and host-floor metadata, artifact size,
image size, archive/SBOM information, and runtime observations when a smoke
records them.

## Build Backends

Native-first ([HOST_NATIVE_ARTIFACTS.md](HOST_NATIVE_ARTIFACTS.md)): for every
derived-image service the portable, relocatable artifact is the source of truth
on every target, and the Docker image is derived from that same rootfs. Each
service has a `services/<service>/recipe.env` file; the dispatcher reads
`ARTIFACT_BACKEND` and chooses the service's build path:

- `nix`: build the root flake's portable runtime using the exact selected
  source, tool versions, and dependency hashes. Auth, the Node services, BEAM,
  Edge Runtime, Postgres, Imgproxy, and Darwin PostgREST use this path.
  [Nix build architecture](NIX_PORTABLE_ARTIFACT_PLAYBOOK.md) explains the
  package definitions and automatic release input resolution.
- `image`: extract selected paths from a published upstream image when that is
  the proven portable path (PostgREST bundles its full ELF closure).
- `upstream-archive`: consume a verified upstream archive for Mailpit or
  Vector; their Linux image path remains an exact mirror rather than an
  artifact-derived image.

The final images are Nix `dockerTools` derivations built from the exact
audited `rootfs/`. The image definition adds only service entry wiring,
static busybox/tini helpers, CA certificates, and the runtime profile from
`services/<service>/runtime.env`. The same derivation emits a deterministic
Docker load archive, so local smoke tests and release publication consume
identical image bytes.

Portable archive builds share two hardening steps. For Nix-backed portable
artifacts, these checks should run inside the Nix package when practical; the
scripts remain available as shared helpers and external verification.

- `scripts/portable-darwin-fixup.sh` completes macOS dylib closures, rewrites
  Nix store install names, removes Nix store rpaths, strips local Mach-O
  symbols, and ad-hoc signs the result.
- `scripts/audit-portable-artifact.sh` fails artifacts that still have
  unresolved runtime dependencies or absolute Nix store references.

Archives use pinned GNU tar and zstd from `nix/archive.nix`, with normalized
ordering, timestamps, ownership, and compression settings. The shell wrapper
copies the selected rootfs into the pure flake release input before invoking
that derivation.

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
missing eligible version tags, oldest first. Each polled service declares a
`release_floor` at the first version published by this repository; the poller
reconciles every matching stable upstream release from that adoption boundary
onward. It dispatches at most three versions per service per poll while keeping
no more than twelve release workflows active across the repository. Active
versions and versions attempted unsuccessfully within the previous six hours
are skipped without blocking later missing versions. The cooldown starts from
GitHub's final workflow update; a successful workflow whose release is not
visible gets a ten-minute publication grace instead. Failures therefore remain
retryable without creating gaps or unbounded hourly fan-out. All configured
polled services are enabled. PostgreSQL release eligibility comes from
published `supabase/postgres` Docker Hub tags, and each native source checkout
is pinned to the one Git commit recorded by that image's provenance. Its policy
accepts only plain `15.x.x.NNN` and `17.x.x.NNN` releases, with independent
floors of `15.14.1.159` and `17.6.1.159`; OrioleDB, architecture-specific, and
other suffixed release tags are ignored.

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
an unsupported tag. A newly triggered build resolves its version-specific
dependency hashes from the exact source automatically. Upstream dependency or
build changes can still fail safely; no release or image is published unless
every build and smoke test passes.

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
- Avoid Alpine unless musl is validated and wins.
- Keep optimizations maintainable; do not carry a phase 2 variant for a tiny
  compressed gain.
- Record rejected experiments. Knowing what is not worth doing is part of the
  asset.

## Status

The release workflow is the primary publication path for service artifacts and
derived Linux images. `.github/workflows/service-artifacts.yml` is the manual
diagnostic path for exercising selected matrix cells and refreshing local
results. The native artifact contract is documented in
[HOST_NATIVE_ARTIFACTS.md](HOST_NATIVE_ARTIFACTS.md). CLI-side integration
(download/verify, process-compose wiring, and an end-to-end Dockerless stack)
and realistic workload/concurrency measurement remain open; see
[SLIM_IMAGES_REPORT.md](SLIM_IMAGES_REPORT.md) § Remaining Work.

## Licensing

The packaging code in this repository is licensed under the [MIT License](LICENSE).
Built artifacts contain independently licensed upstream
software. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); each archive
also carries the license material collected from its dependency closure under
`share/licenses/` and is published with an SPDX SBOM.
