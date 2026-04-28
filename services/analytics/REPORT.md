# Analytics Slim Image Report

Self-contained report for the Analytics/Logflare Linux ARM64 slim-image work.

Last updated: 2026-04-28

## Summary

Analytics has an adopted phase 2 slim image. The current image builds the BEAM
release from source, then removes low-maintenance runtime weight: native debug
symbols, gzipped sourcemaps, curl and its dependency chain, and libraries
already provided by the Debian 13 Distroless C/C++ runtime base.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `supabase/logflare:1.39.2` | `257.0 MiB` compressed |
| Phase 1 slim image | `107.3 MiB` compressed |
| Current phase 2 slim image, `local/analytics:slim-v1.39.2-arm64` | `89.4 MiB` compressed |
| Phase 2 gain vs phase 1 | `17.9 MiB / 16.7%` |
| Current reduction vs upstream | `167.6 MiB / 65.2%` |
| Phase 2 artifact archive | `80.5 MiB` |
| Phase 2 rootfs | `191.0 MiB` |
| Phase 2 local image virtual size | `194.6 MiB` |

## Build Contract

- Current backend: source submodule build.
- Source ref: `v1.39.2`.
- Upstream image: `supabase/logflare:1.39.2`.
- Runtime base: `gcr.io/distroless/cc-debian13:nonroot`.
- Smoke test: `/health` returns `200`.
- `sources/analytics` is read-only.

## Phase 1 Packaging

Analytics is packaged as a BEAM release. The artifact copies:

- The Logflare release.
- CA certificates.
- A small BusyBox shell/tool set.
- The ELF dependency closure.

Debian 13 required normalizing runtime files to `/usr/bin` and `/usr/lib` to
avoid copying over merged-`/usr` symlinks.

Important phase 1 fixes:

- Added BusyBox applets used by BEAM scripts.
- Fixed the ELF dependency crawler regex.
- Normalized copied `/lib` dependencies into `/usr/lib`.

## Phase 2 Changes

- Deleted both `.map` and `.map.gz` files from the release/static output.
- Removed curl from the runtime artifact and dependency scan; the current
  launcher scripts and smoke path do not require it.
- Stripped ELF files in the release, including the large Explorer precompiled
  NIF and Logflare's Rust NIFs.
- Removed libraries already provided by `cc-debian13`: glibc loader/libc,
  OpenSSL 3, `libstdc++`, zlib/zstd, `libm`, `libresolv`, `libgcc_s`, and
  related compatibility linker names.
- Switched the final entrypoint from `/bin/sh` to `/usr/bin/sh` to match the
  merged-`/usr` distroless layout.

## Validation

- Built artifact from `sources/analytics@v1.39.2` with
  `scripts/build-artifact.sh analytics v1.39.2`.
- Built final image with
  `scripts/build-image-from-artifact.sh analytics artifacts/analytics/v1.39.2/linux-arm64/rootfs local/analytics:slim-v1.39.2-arm64`.
- Artifact-mode smoke passed with
  `scripts/smoke.sh analytics --artifact artifacts/analytics/v1.39.2/linux-arm64/rootfs`.
- Final image smoke passed with
  `IMAGE=local/analytics:slim-v1.39.2-arm64 services/analytics/smoke.sh`.
- `sources/analytics` remained clean.

## Decision

Adopted. The compressed image gain is `17.9 MiB`, above the threshold, and the
changes are mechanical packaging changes rather than upstream service changes.

## Follow-Up

- Remove BEAM tools and app modules not needed at runtime, such as compilers,
  dialyzer, typer, and other release extras, if safe.
- Audit whether native dependencies truly require `cc-debian13`; the current
  smoke still keeps it because Analytics ships multiple native NIFs.
- Broaden smoke coverage before removing larger application modules such as
  BigQuery/API client surfaces.
