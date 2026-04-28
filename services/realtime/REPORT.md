# Realtime Slim Image Report

Self-contained report for the Realtime Linux ARM64 slim-image work.

Last updated: 2026-04-28

## Summary

Realtime has an adopted phase 2 slim image. The current image keeps the upstream
BEAM release but uses a repo-owned local/CI launcher and removes runtime
libraries already supplied by the Debian 13 Distroless C/C++ base. An Alpine
BEAM release experiment was also smoke-tested and rejected because it was
larger.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `supabase/realtime:v2.87.0` | `122.8 MiB` compressed |
| Phase 1 slim image | `33.7 MiB` compressed |
| Intermediate phase 2 image | `29.6 MiB` compressed |
| Current phase 2 slim image, `local/realtime:slim-v2.87.0-arm64` | `24.0 MiB` compressed |
| Phase 2 gain vs phase 1 | `9.7 MiB / 28.8%` |
| Current reduction vs upstream | `98.8 MiB / 80.5%` |
| Phase 2 artifact archive | `14.2 MiB` |
| Phase 2 rootfs | `41.8 MiB` |
| Phase 2 local image virtual size | `66.5 MiB` |

## Build Contract

- Current backend: source submodule build.
- Source ref: `v2.87.0`.
- Upstream image: `supabase/realtime:v2.87.0`.
- Runtime base: `gcr.io/distroless/cc-debian13`.
- Smoke test: `/healthcheck` returns `200`.
- `sources/realtime` is read-only; launcher changes live in overlay files.

## Phase 1 Packaging

Realtime is packaged as a BEAM release. Phase 1 established:

- Debian 13 `/usr` normalization for shell/tool paths.
- BusyBox runtime applets for BEAM scripts.
- ELF dependency crawl fixes and `/usr/lib` normalization.

## Phase 2 Changes

- Added `services/realtime/overlay/run.sh`.
- Replaced the production-oriented upstream launcher with a local/CI launcher.
- Kept RLIMIT handling, migrations, optional self-host seeding, and startup as
  `nobody`.
- Removed production-only AWS crash-dump upload, AWS/Fargate metadata lookup,
  and generated cluster certificate handling.
- Dropped bash, curl, jq, iptables, OpenSSL CLI, and the previous `sudo` shim.
- Kept BusyBox shell applets, `setpriv`, `tini`, CA certificates, and release
  runtime dependencies.
- Removed libraries already supplied by `cc-debian13`: glibc loader/libc,
  OpenSSL, libstdc++, zlib/zstd, libm, libresolv, and libgcc.

## Alpine Experiment

We also tested building the BEAM release on Alpine/musl.

Result:

- Smoke passed.
- Image was larger than the accepted Debian 13 Distroless path.
- Rejected because it did not provide a size win and would create a separate
  musl validation surface.

## Validation

- Built source artifact from `sources/realtime@v2.87.0`.
- Built final image as `local/realtime:slim-v2.87.0-arm64`.
- Artifact-mode smoke passed.
- Final image smoke passed with `/healthcheck`.
- Alpine experiment smoke passed but was rejected on size.
- `sources/realtime` remained clean.

## Decision

Adopted. The custom launcher and base-library dedupe save `9.7 MiB` compressed
and remove local/CI-unneeded production concerns without editing upstream
source.

## Follow-Up

- Trim unused BEAM release tools.
- Re-check if `cc-debian13` can become `base-debian13`.
- Broaden smoke coverage before removing more release modules.
