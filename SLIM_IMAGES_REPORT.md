# Supabase Slim Images Report

Global summary for the Linux ARM64 slim-image experiment. Service-specific
details now live next to each service recipe under `services/<service>/REPORT.md`
so each owning team can read a self-contained report.

Last updated: 2026-04-28

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

## Global Result

| Metric | Compressed size |
|---|---:|
| Upstream ARM64 images total | `1753.4 MiB` |
| Phase 1 slim images total | `532.2 MiB` |
| Current best slim images total | `455.7 MiB` |
| Current total reduction vs upstream | `1297.7 MiB / 74.0%` |
| Current total reduction vs phase 1 | `76.5 MiB / 14.4%` |

## Service Summary

| Service | Version | Upstream ARM64 compressed | Current slim compressed | Reduction vs upstream | Runtime base | Smoke | Service report |
|---|---:|---:|---:|---:|---|---|---|
| `postgrest` | `v14.10` | `126.0 MiB` | `21.2 MiB` | `83.2%` | `scratch` | Pass | [services/postgrest/REPORT.md](services/postgrest/REPORT.md) |
| `studio` | `2026.04.27-sha-4afbe9c` | `294.2 MiB` | `128.4 MiB` | `56.4%` | `nodejs22-debian13:nonroot` | Pass | [services/studio/REPORT.md](services/studio/REPORT.md) |
| `edge-runtime` | `v1.73.15` | `360.6 MiB` | `60.8 MiB` | `83.1%` | `base-debian13:nonroot` | Pass | [services/edge-runtime/REPORT.md](services/edge-runtime/REPORT.md) |
| `analytics` | `v1.39.2` | `257.0 MiB` | `89.4 MiB` | `65.2%` | `cc-debian13:nonroot` | Pass | [services/analytics/REPORT.md](services/analytics/REPORT.md) |
| `realtime` | `v2.87.0` | `122.8 MiB` | `24.0 MiB` | `80.5%` | `cc-debian13` | Pass | [services/realtime/REPORT.md](services/realtime/REPORT.md) |
| `pooler` | `v2.9.2` | `287.1 MiB`* | `24.3 MiB` | `91.5%`* | `cc-debian13` | Pass | [services/pooler/REPORT.md](services/pooler/REPORT.md) |
| `pgmeta` | `v0.96.4` | `94.3 MiB` | `52.1 MiB` | `44.8%` | `nodejs20-debian13:nonroot` | Pass | [services/pgmeta/REPORT.md](services/pgmeta/REPORT.md) |
| `storage` | `v1.55.3` | `211.4 MiB` | `55.5 MiB` | `73.7%` | `nodejs24-debian13:nonroot` | Pass | [services/storage/REPORT.md](services/storage/REPORT.md) |

`*` Pooler note: Docker Hub does not currently publish
`supabase/supavisor:2.9.2`. The upstream comparison uses the latest published
Docker Hub tag found during this pass, `supabase/supavisor:2.7.4`, so the
percentage is directional rather than exact.

## Phase 2 Status

| Service | Phase 2 status | Current decision |
|---|---|---|
| `postgrest` | Retained phase 1 as phase 2. | Stable `v14.10` already runs from `scratch`; further gain depends on stable upstream static ARM64 artifacts. |
| `studio` | Not adopted. | Candidate local-dev profile can save `10.9 MiB`, but only if we accept disabling/degrading Sharp image optimization. |
| `edge-runtime` | Adopted. | Nix/native artifact pruning reduced compressed size by `24.8 MiB`. |
| `analytics` | Adopted. | Native stripping, sourcemap-gzip pruning, curl removal, and base-library dedupe reduced compressed size by `17.9 MiB`. |
| `realtime` | Adopted. | Custom local/CI launcher plus base-library dedupe reduced compressed size by `9.7 MiB`. |
| `pooler` | Adopted. | POSIX launcher, native stripping, and base-library dedupe reduced compressed size by `2.5 MiB`. |
| `pgmeta` | Not adopted. | Rolldown and Sentryless experiments saved only `2.4 MiB`, below the maintenance threshold. |
| `storage` | Adopted. | Rolldown emitted-JS bundle with minification reduced compressed size by `21.6 MiB`. |

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
   smoke test.
2. Broaden smoke coverage before adopting local-dev profiles that remove
   feature surfaces.
3. Revisit PostgREST once a stable upstream static ARM64 artifact is published.
4. Decide whether Studio should have a narrower local-development contract.
5. Keep each `services/<service>/REPORT.md` current when service recipes change.
