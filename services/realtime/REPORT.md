# Realtime Slim Image Report

Self-contained report for the Realtime Linux ARM64 slim-image work.

Last updated: 2026-04-29

## Summary

Realtime has an adopted production-ready phase 2 slim image. The current image
keeps the upstream BEAM release, uses a repo-owned launcher aligned with
`supabase/realtime#1837`, and removes runtime libraries already supplied by the
Debian 13 Distroless C/C++ base. An earlier local/CI-only launcher was smaller
but removed too much production startup behavior, so it is no longer the
accepted result.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `supabase/realtime:v2.87.0` | `122.8 MiB` compressed |
| Phase 1 slim image | `33.7 MiB` compressed |
| Over-slimmed local/CI-only phase 2 attempt | `24.0 MiB` compressed |
| Current production-ready phase 2 slim image, `local/realtime:slim-v2.87.0-arm64` | `28.5 MiB` compressed |
| Phase 2 gain vs phase 1 | `5.2 MiB / 15.4%` |
| Current reduction vs upstream | `94.3 MiB / 76.8%` |
| Phase 2 artifact archive | `18.7 MiB` |
| Phase 2 rootfs | `56.8 MiB` |
| Phase 2 local image virtual size | `78.2 MiB` |

## Build Contract

- Current backend: source submodule build.
- Source ref: `v2.87.0`.
- Upstream image: `supabase/realtime:v2.87.0`.
- Runtime base: `gcr.io/distroless/cc-debian13`.
- Smoke test: `/healthcheck` returns `200`, with wrapper command checks and a
  generated-certs fail-fast guard.
- `sources/realtime` is read-only; launcher changes live in overlay files.

## Phase 1 Packaging

Realtime is packaged as a BEAM release. Phase 1 established:

- Debian 13 `/usr` normalization for shell/tool paths.
- BusyBox runtime applets for BEAM scripts.
- ELF dependency crawl fixes and `/usr/lib` normalization.

## Phase 2 Changes

- Added `services/realtime/overlay/run.sh`.
- Added `services/realtime/overlay/rel/env.sh.eex` so AWS Fargate metadata
  parsing no longer depends on `jq`.
- Restored production generated-cluster-certificate support using the same
  dependency-reduction direction as `supabase/realtime#1837`: ECS task
  credentials, `curl`, AWS SigV4 signing with `openssl`, and small shell/awk
  JSON extraction.
- Kept RLIMIT handling, migrations, optional self-host seeding, and startup as
  `nobody` via `setpriv`.
- Kept `awscli`, `jq`, `sudo`, and bash out of the image.
- Did not restore ERL crash-dump S3 upload, because upstream PR #1837 removes
  that behavior.
- Kept BusyBox shell applets, `curl`, `openssl`, `setpriv`, `tini`, CA
  certificates, and release runtime dependencies.
- Removed libraries already supplied by `cc-debian13`: glibc loader/libc,
  OpenSSL, libstdc++, zlib/zstd, libm, libresolv, and libgcc.

## Rejected Local/CI-Only Launcher

The earlier `24.0 MiB` image removed AWS/Fargate metadata lookup and generated
cluster certificate handling. It passed the local smoke test but was rejected
after Realtime team feedback because slim images should stay production ready.

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
- Verified required runtime commands exist in the final image and executed
  `curl --version` plus `openssl version` to catch missing shared libraries.
- Verified `GENERATE_CLUSTER_CERTS=true` fails early with the expected missing
  AWS env error instead of reaching migrations.
- Verified the AWS metadata IPv6 parser chooses the public IPv6 address from a
  fixture.
- Alpine experiment smoke passed but was rejected on size.
- `sources/realtime` remained clean.

## Decision

Adopted. The production-ready launcher and base-library dedupe save `5.2 MiB`
compressed against phase 1 while preserving Realtime production startup
requirements without editing upstream source.

## Follow-Up

- Trim unused BEAM release tools.
- Re-check if `cc-debian13` can become `base-debian13`.
- Broaden smoke coverage before removing more release modules.
