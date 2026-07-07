# Supabase Slim Images Report

Global summary for the Linux ARM64 slim-image experiment. Service-specific
details now live next to each service recipe under `services/<service>/REPORT.md`
so each owning team can read a self-contained report.

Last updated: 2026-07-07

## Measurement Notes

- Target platform: `linux/arm64`.
- Upstream Docker Hub size is the sum of compressed layer sizes from the
  upstream ARM64 manifest, measured with `docker buildx imagetools inspect
  --raw`.
- Slim image sizes are local gzip-compressed Docker archives, measured with
  `docker save IMAGE | gzip -9`.
- Phase 1 means the first working slim pass: base-image replacement plus
  runtime artifact extraction/source build and dependency tracking.
- Phase 2 means accepted service-specific optimization after smoke testing.
- For services where phase 2 was not adopted, the phase 2 column repeats the
  retained phase 1 image size.
- Smoke tests are intentionally small runtime viability checks, not full
  correctness suites.

## Global Result (Footprint Pass 3, 2026-07)

Pass 3 bumped every service to its latest release, onboarded `postgres` (the
largest image in the stack), and added a runtime dimension: steady-state RSS
and idle CPU are now measured during every smoke and recorded in each
`manifest.json`, and every service ships a `runtime.env` low-footprint
local-dev profile baked as overridable image ENV.

| Metric | Compressed size |
|---|---:|
| Upstream ARM64 images total (10 services, current versions) | `2166.9 MiB` |
| Current slim images total | `765.6 MiB` |
| Current total reduction vs upstream | `1401.3 MiB / 64.7%` |

Postgres keeps EVERY extension the upstream image ships (`supabase/postgres`
flavour contract — users can `CREATE EXTENSION` anything locally), so its disk
reduction is limited to Nix build cruft. Its contribution to the 25× goal is
the runtime profile, not disk.

## Service Summary

| Service | Version | Upstream ARM64 compressed | Slim compressed | Reduction | Idle RSS | Idle CPU | Service report |
|---|---:|---:|---:|---:|---:|---:|---|
| `postgres` | `17.6.1.143` (all extensions) | `349.8 MiB` | `294.4 MiB` | `15.8%` | `67.5 MiB` | `0.01%` | [services/postgres/REPORT.md](services/postgres/REPORT.md) |
| `postgrest` | `v14.14` | `145.3 MiB` | `20.3 MiB` | `86.0%` | `29.4 MiB` | `0.13%` | [services/postgrest/REPORT.md](services/postgrest/REPORT.md) |
| `studio` | `2026.06.29-sha-20290c7` | `304.7 MiB` | `136.3 MiB` | `55.3%` | `201.4 MiB` | `0.00%` | [services/studio/REPORT.md](services/studio/REPORT.md) |
| `edge-runtime` | `v1.74.2` (no-AI) | `360.6 MiB` | `52.7 MiB` | `85.4%` | `15.1 MiB` | `0.02%` | [services/edge-runtime/REPORT.md](services/edge-runtime/REPORT.md) |
| `analytics` | `v1.46.0` | `258.9 MiB` | `89.7 MiB` | `65.4%` | `507.2 MiB` | `0.50%` | [services/analytics/REPORT.md](services/analytics/REPORT.md) |
| `realtime` | `v2.112.6` | `114.7 MiB` | `28.4 MiB` | `75.2%` | `163.2 MiB` | `0.13%` | [services/realtime/REPORT.md](services/realtime/REPORT.md) |
| `pooler` | `v2.9.10` | `289.4 MiB`* | `24.3 MiB` | `91.6%`* | `154.9 MiB` | `0.07%` | [services/pooler/REPORT.md](services/pooler/REPORT.md) |
| `pgmeta` | `v0.96.6` | `94.2 MiB` | `52.7 MiB` | `44.1%` | `79.4 MiB` | `0.70%` | [services/pgmeta/REPORT.md](services/pgmeta/REPORT.md) |
| `storage` | `v1.62.6` | `223.5 MiB` | `55.6 MiB` | `75.1%` | `211.5 MiB` | `0.19%` | [services/storage/REPORT.md](services/storage/REPORT.md) |
| `auth` | `v2.192.0` | `25.8 MiB` | `11.2 MiB` | `56.6%` | `24.8 MiB` | `0.58%` | [services/auth/REPORT.md](services/auth/REPORT.md) |

`*` Pooler note: Docker Hub publishes up to `supabase/supavisor:2.9.7`; the
upstream comparison uses that tag, so the percentage is directional.

## Runtime Footprint (the 25-parallel-stacks view)

RSS multiplies per stack; image size does not (layers are stored once).
Measured steady-state RSS with the pass-3 runtime profiles:

- Core stack (postgres + auth + postgrest): `121.7 MiB` per stack —
  ~`3.0 GiB` for 25 parallel stacks.
- Adding realtime (+163) and storage (+212) per stack stays viable
  (~`12.5 GiB` at 25 stacks).
- **Decision (2026-07): `analytics` (`507 MiB`) and `studio` (`201 MiB`) are
  disabled by default in the minimal local stack.** Their slim images exist
  for when they are enabled; sharing one instance across stacks is the
  follow-up for the enabled case.
- The BEAM scheduler profile (`+S 1:1 +sbwt none ...`) eliminated idle
  busy-wait CPU across realtime/analytics/pooler (all ≤ 0.5% idle).

## Phase 2 Status

| Service | Phase 2 status | Current decision |
|---|---|---|
| `postgrest` | Retained phase 1 as phase 2. | Stable `v14.10` already runs from `scratch`; further gain depends on stable upstream static ARM64 artifacts. |
| `studio` | Not adopted. | Candidate local-dev profile can save `10.9 MiB`, but only if we accept disabling/degrading Sharp image optimization. |
| `edge-runtime` | Adopted. | Nix/native artifact pruning reduced compressed size by `24.8 MiB`. |
| `analytics` | Adopted. | Native stripping, sourcemap-gzip pruning, curl removal, and base-library dedupe reduced compressed size by `17.9 MiB`. |
| `realtime` | Adopted. | Production-ready launcher aligned with `supabase/realtime#1837` plus base-library dedupe reduced compressed size by `5.2 MiB`; the earlier `24.0 MiB` local/CI-only launcher was rejected as over-slimmed. |
| `pooler` | Adopted. | POSIX launcher, native stripping, and base-library dedupe reduced compressed size by `2.5 MiB`. |
| `pgmeta` | Not adopted. | Rolldown and Sentryless experiments saved only `2.4 MiB`, below the maintenance threshold. |
| `storage` | Adopted. | Rolldown emitted-JS bundle with minification reduced compressed size by `21.6 MiB`. |
| `auth` | Not adopted. | Static Go executable already runs from `scratch`; phase 2 repeats phase 1 because further binary-level experiments are not worth carrying. |

## Cross-Service Lessons

- Debian 13 Distroless works across all non-`scratch` services, but merged
  `/usr` means artifacts must avoid copying top-level `/bin` or `/lib` over
  symlinks in the base image.
- `ldd` is not enough for glibc runtime completeness. NSS modules such as
  `libnss_dns.so.2` may be loaded dynamically and must be copied explicitly
  when an app resolves Docker service names.
- For BEAM releases, BusyBox applets are a practical way to satisfy shell
  script assumptions without carrying a general-purpose distro image.
- For Node services, a green upstream-build artifact is a better starting point
  than prematurely forcing a bundler through type-only exports and optional
  native binaries.
- Raw filesystem size is not the same as compressed image impact. Studio showed
  this clearly: `stripe-experiment-sync` is `26 MiB` raw but only about
  `1.9 MiB` compressed.

## Remaining Work

1. Add CI jobs that build each current slim artifact/image and run the matching
   smoke test (only edge-runtime has a workflow today; postgres and the
   docker-image backend need one too).
2. CLI-level follow-ups surfaced by the runtime measurements: run `analytics`
   and `studio` as shared singletons (or default-off) for parallel stacks;
   wire memory limits through `container.HostConfig.Resources`.
3. Revisit PostgREST once a stable upstream static ARM64 artifact is published.
4. Longer-idle CPU sample for postgres (measured 10s after migrations; add a
   per-service settle override to the measurement pipeline).
5. Storage module-level pruning of AWS/Smithy/Iceberg surfaces — the object
   round-trip smoke added in pass 3 is the safety net it was waiting for.
6. Further analytics RSS reduction requires upstream boot-time feature flags
   (Broadway/ETS allocations dominate its ~500 MiB idle footprint).
7. Keep each `services/<service>/REPORT.md` current when service recipes change.
