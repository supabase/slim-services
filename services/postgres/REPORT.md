# Postgres Slim Image Report

## Summary

`supabase/postgres` is a Nix-based image: the entire runtime comes from the
repo-owned portable artifact for the selected PostgreSQL major (15 or 17),
including the extension set shipped by that major's upstream Dockerfile.

## Build Contract

- Backend: `nix` — `Dockerfile.artifact` evaluates the pinned source tree with
  the repo-owned package overlay and exports the selected
  `psql_15_cli_portable` or `psql_17_cli_portable` rootfs.
- The artifact is built from the exact source commit resolved from the
  requested Docker Hub tag; no upstream portable package is consumed.
- PG15 keeps the full `ourExtensions` set (including TimescaleDB and plv8).
  PG17 uses the matching filtered set because those two extensions are not
  compatible with that major. Extensions are installed but not enabled by
  default beyond the required preload set.
- Portable packaging uses latest-only extension outputs and bundles the
  minimal glibc locale archive on Linux; copied libraries are patched to
  relative paths so the rootfs remains relocatable.
- Local-dev config overlay at `/etc/postgresql-custom/conf.d/99-local-dev.conf`
  (loaded through the stock `include_dir`), all values overridable via
  `postgres -c`:
  `shared_buffers=32MB`, `effective_cache_size=128MB`,
  `maintenance_work_mem=32MB`, `max_connections=50`, `max_wal_size=128MB`,
  `jit=off`, `autovacuum_naptime=60s`, `bgwriter_delay=2000ms`,
  `wal_writer_delay=2000ms`. `wal_level=logical` is left untouched (realtime
  requires it).
- The derived image provides a small busybox/bash tools stage, the bundle at
  `/opt/postgres`, and the repo-owned entrypoint that performs initdb,
  migrations, and Docker networking setup as uid 65532.

## What still works (smoke-verified)

- initdb + supabase init scripts + migrations on first boot.
- `CREATE EXTENSION` for the supported set including the heavy families:
  pgcrypto, pgjwt, uuid-ossp, pg_trgm, hstore, pg_stat_statements, pg_graphql,
  pg_net, pg_cron, vector, hypopg, index_advisor, pg_jsonschema, pg_hashids,
  http, pgaudit, pg_tle, rum, pgsodium, supabase_vault, pgtap, pgmq,
  pg_partman, pg_repack, plpgsql_check, postgis, postgis_topology,
  address_standardizer, pgrouting, pgroonga, wrappers. PG15 additionally
  exercises TimescaleDB and plv8; those extensions are omitted from the PG17
  package because they are incompatible with that major.

## What is intentionally dropped

Only non-runtime content: Nix tooling and build derivations, store paths not
reachable from the runtime roots, alternate switchable extension versions
(defaults stay), kernel firmware/apk leftovers under `/lib`. No extension is
removed from the selected major's upstream extension set.

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

## Host-Native darwin-arm64 Artifact (2026-07)

Reversal of the plan's original non-goal (user directive): this repo now owns
the self-contained postgres too. `sources/postgres` is pinned to the same tag
as the Docker image, and the artifact is our relocatable package —
`psql_15_cli_portable` or `psql_17_cli_portable` from
`nix/packages/postgres-portable.nix` — with a repo-owned overlay
(`services/postgres/nix/packages/`) keeping each major's upstream extension
set and portable layout in sync:

- **pgvector added to the CLI extension set** (the documented parity gap in
  the CLI's postgres distribution).
- Stale `/nix/store` LC_RPATH entries scrubbed from the copied ICU dylibs
  (upstream rewrites install names but not rpaths; our portable audit
  rejects them).

Two upstream packaging bugs surfaced and are guarded against in shared
tooling now:

- `lib/libiconv.dylib` (a reexport stub) ships with an **invalid code
  signature** — macOS SIGKILLs any process loading it via
  `DYLD_LIBRARY_PATH`. `build-artifact-from-nix.sh` repairs invalid
  signatures with the host `codesign` after the rootfs copy, and
  `audit-portable-artifact.sh --darwin` now verifies every Mach-O signature,
  failing the build otherwise. The CLI's shipped artifact should be checked
  for the same class of issue.

Smoke (host process, no Docker anywhere): initdb → pg_ctl with the preload
set (`pg_stat_statements,pg_cron,pg_net`, plus TimescaleDB on PG15) →
`CREATE EXTENSION` for the selected major's compatible set → a pgvector
nearest-neighbour round-trip. Re-run from an untarred archive in a scratch
directory (relocatable). pgsodium/supabase_vault ship in the artifact but
need the CLI's getkey config to exercise; that belongs to the CLI's smoke.

Local verification note: everything above was verified locally except
compiling pg_graphql (a pgrx build whose crates.io vendoring is blocked by
UA filtering on this network — same extension the CLI already ships, and the
committed recipe includes it; CI builds it via upstream's binary cache).

| Metric | Value |
|---|---:|
| Archive (PG17 example, `postgres-17.6.1.143-darwin-arm64.tar.zst`) | `30.4 MiB` |
| rootfs | `110.2 MiB` |
| Steady-state RSS (host process, idle, 60s settle) | `34.0 MiB` |
| Idle CPU | `0.0 %` |

### Native-first, no exceptions (2026-07, user directive)

The portable artifact is now the basis for the Docker image too, on every
target — an accepted divergence from upstream supabase/postgres bundling:

- The artifact and image ship the **full extension set for the selected major**
  — everything the matching upstream image supports. PG15 includes
  TimescaleDB/plv8; PG17 omits them because they are incompatible. Installed is
  not enabled: only the minimal
  `shared_preload_libraries` set (pg_stat_statements, pg_cron, pg_net,
  pgsodium, supabase_vault, supautils; plus TimescaleDB on PG15) is on by
  default, so the measured
  footprint is unchanged; pgaudit/pg_stat_monitor/pg_tle need a preload
  opt-in to CREATE. Disk grows accordingly (~30 -> ~250-300 MiB archive
  expected).
- `Dockerfile.artifact` is a nixos/nix flake builder producing the same
  portable rootfs as darwin (`--accept-flake-config` uses upstream's binary
  cache).
- `Dockerfile.slim` derives the image: distroless `base-debian13:nonroot` +
  busybox/bash tools stage + the bundle at `/opt/postgres` + repo-owned
  `entry.sh`. First boot delegates to the bundle's own
  `supabase-postgres-init.sh` (initdb, CLI config templates with pgsodium
  getkey wired, password), then appends the docker network settings
  (`listen_addresses='*'`, port 5432, `wal_level=logical`, a network
  scram pg_hba rule) and the low-footprint profile, runs the bundled
  supabase migrations against a temporary socket-only server, and starts
  postgres — all as uid 65532 (no gosu/root phase, unlike the upstream
  image).
- The image smoke checks the broad preload-free set (including
  postgis/pgroonga/wrappers and, on PG15, TimescaleDB/plv8), a pgsodium/vault
  round-trip through the getkey wiring, and a pgvector nearest-neighbour
  query; the host smoke creates the same subset minus the getkey-dependent
  pair.

Verification happens in CI (`service-artifacts.yml`) per the directive —
no local build for this step; the portable artifact underneath is the one
already verified above.

First CI run findings (run 28898115404): darwin passed with the full set
(including the pgrx extensions — the platform worry didn't materialize);
Linux failed twice-over and both fixes live in the packaging: the image
tools stage was missing the `od` busybox applet that
`pgsodium_getkey.sh` needs (server died with "invalid secret key"), and the
default upstream build ships EVERY historical version of every extension
(16x wrappers, 17x pg_graphql — mostly large pgrx cdylibs), inflating the
rootfs to ~5.3 GiB. The overlay now passes upstream's `latestOnly = true`,
which ships only the latest of each extension and additionally bundles
glibcLocalesMinimal on Linux.

### Supautils allowlist parity with the docker.io image (2026-08)

Upstream's CLI config template (`nix/packages/cli-config/postgresql.conf.template`)
preloads supautils but never sets `supautils.privileged_extensions`, so the
non-superuser `postgres` role could not `CREATE EXTENSION pg_net` on a fresh
database — breaking the CLI's shadow-database flows (`db diff`, `db pull`,
declarative sync) whenever webhooks are enabled. The docker.io image gets
these settings from `ansible/files/postgresql_config/supautils.conf.j2`; the
overlay's `configBundle` now appends that same file (from the exact source
checkout being built, so the lists cannot drift) to the bundled template,
fixing both the derived image and native host use of the artifact. For PG17,
the incompatible timescaledb/plv8 entries are stripped the same
way upstream's Dockerfile-17 strips them; PG15 retains both values. The build
refuses the append if the `.j2` ever grows real Jinja templating. Smokes:
the host smoke asserts the shipped template carries the allowlist; the image
smoke creates `pg_net` live as the demoted `postgres` role (the CLI
shadow-db path). Everything the appended block references exists on slim
first boot (`supabase_privileged_role` is created by the bundled
migrations); the missing `/etc/postgresql-custom/extension-custom-scripts`
path is tolerated by supautils. Drop the append once the upstream template
carries the block itself.
