# Postgres Slim Image Report

## Summary

`supabase/postgres` is a Nix-based image: the entire runtime lives in
`/nix/store` (~1.3 GiB uncompressed), including many extensions that local
development rarely needs. This service prunes the published upstream image
(no source build) into a local-development profile.

## Build Contract

- Backend: `docker-image` — `Dockerfile.artifact` starts `FROM $SOURCE_IMAGE`
  and runs `prune.sh` inside the upstream image, writing a reduced rootfs.
- `prune.sh` walks the Nix reference graph (`nix-store --query --references`)
  from real roots (`/usr/local/bin`, `/bin`, `/usr/lib/postgresql`, `/etc`,
  `/docker-entrypoint-initdb.d`, the active profile) and copies only the
  reachable store paths. **Every extension the upstream image ships is kept**
  — this is the `supabase/postgres` flavour; users can `CREATE EXTENSION`
  anything Supabase supports locally. Only non-runtime content is dropped:
  - Nix tooling (`nix`, `nix-store`, ...) and `.drv` build derivations
  - store paths unreachable from the runtime roots (the upstream image ships
    ~6,700 store paths; the runtime closure is a few hundred)
- Version-switch developer scripts (`switch_*_version`) are removed before the
  walk so ALTERNATE extension versions do not enter the closure; the default
  version of every extension stays. Dangling symlinks are swept.
- Local-dev config overlay at `/etc/postgresql-custom/conf.d/99-local-dev.conf`
  (loaded through the stock `include_dir`), all values overridable via
  `postgres -c`:
  `shared_buffers=32MB`, `effective_cache_size=128MB`,
  `maintenance_work_mem=32MB`, `max_connections=50`, `max_wal_size=128MB`,
  `jit=off`, `autovacuum_naptime=60s`, `bgwriter_delay=2000ms`,
  `wal_writer_delay=2000ms`. `wal_level=logical` is left untouched (realtime
  requires it).
- Entrypoint, gosu, busybox userland, `/etc`, and the init/migration scripts
  are preserved unchanged, so the CLI's `docker run` contract is identical to
  the upstream image.

## What still works (smoke-verified)

- initdb + supabase init scripts + migrations on first boot.
- `CREATE EXTENSION` for the supported set including the heavy families:
  pgcrypto, pgjwt, uuid-ossp, pg_trgm, hstore, pg_stat_statements, pg_graphql,
  pg_net, pg_cron, vector, hypopg, index_advisor, pg_jsonschema, pg_hashids,
  http, pgaudit, pg_tle, rum, pgsodium, supabase_vault, pgtap, pgmq,
  pg_partman, pg_repack, plpgsql_check, postgis, postgis_topology,
  address_standardizer, pgrouting, pgroonga, wrappers.

## What is intentionally dropped

Only non-runtime content: Nix tooling and build derivations, store paths not
reachable from the runtime roots, alternate switchable extension versions
(defaults stay), kernel firmware/apk leftovers under `/lib`. No extension is
removed. (plv8/pljava/plcoffee/plls/timescaledb are not present in the
upstream arm64 image to begin with.)

## Measurements (17.6.1.143, linux/arm64, full extension set, 2026-07)

| Metric | Upstream | Slim | Reduction |
|---|---:|---:|---:|
| Compressed image | `349.8 MiB` (Docker Hub arm64 layers) | `293.9 MiB` (`docker save \| gzip -9`) | `15.8%` |
| Uncompressed rootfs | ~`1300 MiB` | `1129 MiB` | `13.2%` |

| Runtime metric | Value |
|---|---:|
| Steady-state RSS (settled) | `67.5 MiB` |
| RSS right after initdb + migrations + 31 CREATE EXTENSION | `110.9 MiB` |
| Idle CPU (settled) | `0.01 %` |

The disk reduction is intentionally modest: every extension the upstream image
ships stays available (`supabase/postgres` flavour contract), so only Nix
tooling, build derivations, unreferenced store paths, and alternate switchable
extension versions are dropped. The per-stack win at 25 parallel stacks comes
from the runtime profile: `shared_buffers=32MB`, `jit=off`, slowed idle ticks
(all smoke-verified via the conf.d overlay, `wal_level=logical` untouched).

An earlier pass that additionally deny-listed PostGIS/pgroonga/wrappers/perl
measured `99.0 MiB` compressed / `431 MiB` rootfs — rejected because the local
image must support every extension a user may enable. If a "core" variant is
ever wanted alongside the full flavour, that deny list is in git history
(`b54916b`).
