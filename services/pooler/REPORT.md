# Pooler Slim Image Report

Self-contained report for the Supavisor/Pooler Linux ARM64 slim-image work.

Last updated: 2026-04-28

## Summary

Pooler has an adopted phase 2 slim image. The current image builds the BEAM
release from source, replaces the upstream bash-based limits script with a POSIX
overlay, strips native ELF files, and removes libraries already supplied by the
Debian 13 Distroless C/C++ base. The service still carries Bullseye OpenSSL 1.1
runtime libraries because the BEAM release requires them.

## Measurements

| Metric | Size |
|---|---:|
| Comparison upstream ARM64 image, `supabase/supavisor:2.7.4` | `287.1 MiB` compressed |
| Phase 1 slim image, `v2.9.2` | `26.8 MiB` compressed |
| Current phase 2 slim image, `local/pooler:slim-v2.9.2-arm64` | `24.3 MiB` compressed |
| Phase 2 gain vs phase 1 | `2.5 MiB / 9.3%` |
| Directional reduction vs comparison upstream | `262.8 MiB / 91.5%` |
| Phase 2 artifact archive | `14.4 MiB` |
| Phase 2 rootfs | `40.9 MiB` |
| Phase 2 local image virtual size | `67.4 MiB` |

Docker Hub note: `supabase/supavisor:2.9.2` is not currently published, so the
upstream comparison uses the latest published tag found during this pass,
`supabase/supavisor:2.7.4`.

## Build Contract

- Current backend: source submodule build.
- Source ref: `v2.9.2`.
- Runtime base: `gcr.io/distroless/cc-debian13`.
- Smoke test: `/api/health` returns `204`.
- `sources/pooler` is read-only; launcher/limits changes live in overlays.

## Phase 1 Packaging

Important phase 1 fixes:

- Added missing `hostname` BusyBox applet.
- Set runtime defaults for `RLIMIT_NOFILE` and `NODE_IP`.
- Added `ELIXIR_ERL_OPTIONS=+fnu` to avoid native filename encoding warnings.
- Bundled glibc NSS DNS/files modules explicitly because they are loaded
  dynamically and do not show up in `ldd`; without them, Docker service names
  failed with `:nxdomain`.
- Normalized `/bin` and `/lib` to the Debian 13 merged-`/usr` layout.

## Phase 2 Changes

- Added `services/pooler/overlay/limits.sh`, a POSIX shell equivalent of
  upstream `limits.sh`.
- Switched final entrypoint and command from `/bin/sh` to `/usr/bin/sh`, backed
  by BusyBox and matching the merged-`/usr` distroless layout.
- Removed bash from the artifact runtime.
- Stripped native ELF files in the release, including the Rust NIF
  `libpgparser.so`.
- Removed libraries already provided by `gcr.io/distroless/cc-debian13`:
  glibc loader/libc, `libdl`, `libgcc_s`, `libm`, NSS DNS/files,
  `libpthread`, `libresolv`, `librt`, `libstdc++`, and `libutil`.
- Kept Bullseye `libcrypto.so.1.1` and `libtinfo.so.6`, because the
  Bullseye-built BEAM release still needs them and Debian 13 Distroless does
  not provide OpenSSL 1.1.

## Validation

- Built artifact from `sources/pooler@v2.9.2` with
  `scripts/build-artifact.sh pooler v2.9.2`.
- Built final image with
  `scripts/build-image-from-artifact.sh pooler artifacts/pooler/v2.9.2/linux-arm64/rootfs local/pooler:slim-v2.9.2-arm64`.
- Artifact-mode smoke passed.
- Final image smoke passed with
  `IMAGE=local/pooler:slim-v2.9.2-arm64 services/pooler/smoke.sh`.
- `sources/pooler` remained clean.

## Decision

Adopted. The gain is smaller than Storage, Edge Runtime, Analytics, or
Realtime, but the changes are mechanical, local to this repo, and keep upstream
source untouched.

## Follow-Up

- Investigate the upstream Nix flake as a candidate backend.
- Trim BEAM release extras.
- Decide whether the artifact can run nonroot after wrapper/env cleanup.
- Explore a build path that moves off Bullseye/OpenSSL 1.1.
