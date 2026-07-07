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
  reachable store paths, skipping a deny list of heavyweight packages:
  - PostGIS stack: `postgis`, `sfcgal`, `gdal`, `geos`, `proj`, `boost`,
    `pgrouting`
  - Full-text tokenizer stack: `pgroonga`, `groonga`, `kytea`, `mecab`
  - `wrappers`, `plv8`, `timescaledb`, `perl` (plperl), nix tooling, `.drv`
    build derivations
- Version-switch developer scripts (`switch_*_version`) are removed before the
  walk so alternate extension versions do not enter the closure.
- Denied extension payloads (`.so`, `extension/*.control`, `*.sql`) are also
  deleted from the copied postgres lib dirs, and dangling symlinks are swept.
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
- `CREATE EXTENSION` for the local-dev set: pgcrypto, pgjwt, uuid-ossp,
  pg_trgm, hstore, pg_stat_statements, pg_graphql, pg_net, pg_cron, vector,
  hypopg, index_advisor, pg_jsonschema, pg_hashids, http, pgaudit, pg_tle,
  rum, pgsodium, supabase_vault, pgtap.
- Denied extensions are verified ABSENT (`CREATE EXTENSION postgis` fails).

## What is intentionally dropped

PostGIS (+ raster/sfcgal/topology/tiger), pgrouting, pgroonga, plv8/plls/
plcoffee, plperl, wrappers, timescaledb — projects that need these should use
the upstream `supabase/postgres` image (config.toml image override).

## Measurements (17.6.1.143, linux/arm64, 2026-07)

| Metric | Upstream | Slim | Reduction |
|---|---:|---:|---:|
| Compressed image | `349.8 MiB` (Docker Hub arm64 layers) | `99.0 MiB` (`docker save \| gzip -9`) | `71.7%` |
| Uncompressed rootfs | ~`1300 MiB` | `431 MiB` | `66.8%` |

| Runtime metric | Value |
|---|---:|
| Steady-state RSS (after initdb + migrations + 21 CREATE EXTENSION) | `70.1 MiB` |
| CPU 10s after smoke activity | `9.2 %`* |

`*` sampled immediately after initdb/migrations/extension creation; background
workers (autovacuum, pg_cron, checkpointer) were still settling. A longer-idle
sample is a follow-up once the measurement pipeline supports per-service settle
overrides.

Smoke-verified: `shared_buffers=32MB`, `jit=off`, `wal_level=logical` active
via the conf.d overlay; denied extensions absent (`CREATE EXTENSION postgis`
fails); basic SQL round-trip.
