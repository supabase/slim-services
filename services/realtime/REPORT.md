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

## Footprint Pass 3 (runtime profile, 2026-07)

- Bumped `sources/realtime` to `v2.112.6` (latest release; CLI pins v2.112.2).
  Artifact build updates: `beacon` path dep removed upstream, new local `forum`
  path dep copied before `mix deps.get`.
- Trimmed BEAM release tooling from the artifact (erts `ct_run`/`dialyzer`/
  `typer`/`erlc`/`escript`/`yielding_c_fun`, lib `src`/`include`/`c_src` dirs,
  erts doc/man).
- Added `runtime.env` low-footprint defaults baked as image ENV (overridable):
  `ELIXIR_ERL_OPTIONS=+fnu +S 1:1 +SDio 1 +sbwt none +sbwtdcpu none +sbwtdio none`
  (single scheduler, no scheduler busy-wait — the busy-wait removal is the big
  idle-CPU win at 25 parallel stacks) and `DB_POOL_SIZE=2` (metadata repo pool
  holds server-side postgres backends; upstream default 5).
- Note: upstream v2.112.x images bundle a `pgdelta` helper binary built in the
  upstream Dockerfile; it is not referenced from the Elixir application code
  (Dockerfile-only), so the slim image omits it.

| Metric | Value |
|---|---:|
| Image compressed (`docker save \| gzip -9`) | `28.4 MiB` |
| Steady-state RSS (idle, after /healthcheck) | `163.2 MiB` |
| Idle CPU | `0.13 %` |

## Host-Native darwin-arm64 Artifact (2026-07)

First BEAM service on the host-native contract (HOST_NATIVE_PLAN.md), built by
the repo-owned Nix package `services/realtime/nix/default.nix` (applied over
the read-only submodule via `NIX_PACKAGE_OVERLAY`; Linux keeps the Docker
artifact builder unchanged):

- NIF inventory (fast-fail check): only OTP-standard NIFs (crypto, asn1,
  runtime_tools) — no app-level native code, so a plain `mixRelease` works.
- `mixRelease` with ERTS included; the Elixir minor and OTP major are derived
  from the checked-out upstream Dockerfile. Their source definitions come
  from a newer immutable nixpkgs revision while dependencies stay on the
  shared package set and its established glibc floor. For v2.123.5 that
  selects Elixir 1.19.5 and OTP 28.5.0.5 (upstream pins OTP 28.5.0.4).
  Dependencies remain pinned by a fixed-output `fetchMixDeps` hash.
- Portable packaging in the derivation: every Nix-store dylib the release
  references (openssl for the crypto NIF, ncurses/zlib/libc++ for ERTS) is
  bundled into `dylib/`, install names rewritten to `@rpath` with
  `@loader_path`-relative rpaths, ad-hoc signed; mixRelease's PATH-wrapper
  shims and Nix shebangs are removed; the build fails if any shipped Mach-O
  or launch script still references `/nix/store`.
- Profile note: `mix assets.deploy` (esbuild/tailwind dashboard assets) is
  skipped — no `cache_static_manifest` is configured, so the service works
  fully; only LiveDashboard UI assets 404. Same philosophy as edge-runtime's
  no-AI profile.
- Smoke (host process, `runtime.env` applied): `bin/migrate`, seeds
  (`Realtime.Release.seeds/1`), then `bin/server`; `/healthcheck` returns 200.
  Re-run from an untarred archive in a scratch directory (relocatable).
  `scripts/audit-portable-artifact.sh --darwin` clean.

| Metric | Value |
|---|---:|
| Archive (`realtime-v2.112.6-darwin-arm64.tar.zst`) | `11.9 MiB` |
| rootfs | `40.8 MiB` |
| Steady-state RSS (host process, idle) | `222.7 MiB` |
| Idle CPU | `0.33 %` |

Host RSS runs higher than the container number (~163 MiB): same release, but
the host BEAM sizes its allocators for the machine rather than a cgroup.
Tuning beyond the existing `+S 1:1` profile is follow-up work.

### Native-first convergence (2026-07)

The Nix package now builds the Linux artifacts too (patchelf `$ORIGIN`
rpaths + system loader; in-derivation ldd audit), and `Dockerfile.slim`
derives the image from that rootfs (distroless `base-debian13:nonroot` +
busybox/tini/CA stage + `entry.sh`: migrate → optional seeds → server). The
docker-source builder is gone; the old run.sh cloud bootstrap (Fly/ECS cert
generation) is not part of the local/CI image. linux-arm64 verified: derived
image smoke green (RSS 162.8 MiB ≈ before; 26.6 MiB gzip, was 28.4) and the
archive runs as a bare host process on a store-less Debian (healthcheck 200).
Found in the process: nixpkgs compiles an absolute Nix-store bash path into
OTP's `disksup.beam` — disksup is disabled via `vm.args` in the portable
packaging (see NIX_PORTABLE_ARTIFACT_PLAYBOOK.md).
