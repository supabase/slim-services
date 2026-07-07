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

## Footprint Pass 3 (runtime profile, 2026-07)

- Bumped `sources/pooler` to `v2.9.10` (latest release; CLI pins 2.9.7).
- Added `runtime.env` baked as image ENV (overridable):
  `ELIXIR_ERL_OPTIONS=+S 1:1 +SDio 1 +sbwt none +sbwtdcpu none +sbwtdio none`.
  The pooler is opt-in for local dev; raise scheduler count for load testing.
- Smoke now records steady-state runtime metrics into `manifest.json`.
- OpenSSL 1.1/Bullseye carry-over and the upstream Nix flake backend remain
  open follow-ups (unchanged this pass).

| Metric | Value |
|---|---:|
| Image compressed (`docker save \| gzip -9`) | `24.3 MiB` |
| Steady-state RSS (idle, after /api/health) | `154.9 MiB` |
| Idle CPU | `0.07 %` |

## Host-Native darwin-arm64 Artifact (2026-07)

Built by the repo-owned Nix package `services/pooler/nix/default.nix`,
adapted from upstream's `nix/package.nix` (which supports aarch64-darwin but
is stale: it points at `native/pgparser/Cargo.lock` while the workspace lock
lives at `native/Cargo.lock`). Same portable-BEAM packaging as realtime
(see `services/realtime/REPORT.md`), plus the supavisor-specific parts:

- NIF inventory: OTP-standard NIFs + `libpgparser.so`, a Rust (rustler)
  wrapper around libpg_query. Cargo deps are vendored via `importCargoLock`;
  the vendor copy must be writable because pg_query's build script writes
  generated protobuf bindings back into the crate source.
- `native/pgparser/.cargo/config.toml` already ships the macOS
  `-undefined dynamic_lookup` link flags rustler NIFs need.
- Elixir 1.18.4 / OTP 27.3.4.6 from pinned nixpkgs (Docker builder: 1.18.2 /
  27.2.1 — same majors, newer patches).
- Smoke (host process, `runtime.env` applied): `bin/migrate`, then
  `bin/server`; authenticated `/api/health` returns 204. Re-run from an
  untarred archive in a scratch directory (relocatable).
  `scripts/audit-portable-artifact.sh --darwin` clean.

| Metric | Value |
|---|---:|
| Archive (`pooler-v2.9.10-darwin-arm64.tar.zst`) | `23.6 MiB` |
| rootfs | `52.4 MiB` |
| Steady-state RSS (host process, idle) | `214.0 MiB` |
| Idle CPU | `0.0 %` |

### Native-first convergence (2026-07)

Same convergence as realtime: the Nix package builds the Linux artifacts
(pg_query's bindgen needs `rustPlatform.bindgenHook` on Linux), and
`Dockerfile.slim` derives the image from the rootfs (`entry.sh`: RLIMIT hook
→ migrate → server; replaces limits.sh + docker-source). linux-arm64
verified: derived image smoke green (authenticated `/api/health` 204, RSS
159.0 MiB ≈ before; 39.0 MiB gzip vs 24.3 — the artifact now carries
openssl/libstdc++/ncurses itself instead of leaning on distroless-cc, the
cost of one rootfs serving native and Docker), and the archive runs as a
bare host process on a store-less Debian. disksup disabled via `vm.args`
(see realtime's note).
