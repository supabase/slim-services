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
  `maintenance_work_mem=32MB`, `max_connections=100`, `max_wal_size=128MB`,
  `jit=off`, `autovacuum_naptime=60s`, `bgwriter_delay=2000ms`,
  `wal_writer_delay=2000ms`. `wal_level=logical` is left untouched (realtime
  requires it).
- Gosu, busybox userland, `/etc`, and the init/migration scripts are preserved
  unchanged. The image entrypoint is a thin wrapper (`slim-entrypoint.sh`) that
  restores postgres ownership of `/etc/postgresql*` (lost when Docker COPY
  assembles the scratch image) and then execs the stock
  `docker-entrypoint.sh`, so the CLI's `docker run` contract is otherwise
  identical to the upstream image.

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

## Host-Native darwin-arm64 Artifact (2026-07)

Reversal of the plan's original non-goal (user directive): this repo now owns
the self-contained postgres too. `sources/postgres` is pinned to the same tag
as the Docker image, and the artifact is upstream's own relocatable package —
`psql_17_cli_portable` from `nix/packages/postgres-portable.nix`, the exact
build the Supabase CLI ships — with a repo-owned overlay
(`services/postgres/nix/packages/`) making two changes:

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
set (`pg_stat_statements,pg_cron,pg_net`) → `CREATE EXTENSION` for pgcrypto,
pg_stat_statements, **vector**, pg_net, pg_cron → a pgvector
nearest-neighbour round-trip. Re-run from an untarred archive in a scratch
directory (relocatable). pgsodium/supabase_vault ship in the artifact but
need the CLI's getkey config to exercise; that belongs to the CLI's smoke.

Local verification note: everything above was verified locally except
compiling pg_graphql (a pgrx build whose crates.io vendoring is blocked by
UA filtering on this network — same extension the CLI already ships, and the
committed recipe includes it; CI builds it via upstream's binary cache).

| Metric | Value |
|---|---:|
| Archive (`postgres-17.6.1.143-darwin-arm64.tar.zst`) | `30.4 MiB` |
| rootfs | `110.2 MiB` |
| Steady-state RSS (host process, idle, 60s settle) | `34.0 MiB` |
| Idle CPU | `0.0 %` |

### Native-first, no exceptions (2026-07, user directive)

The portable artifact is now the basis for the Docker image too, on every
target — an accepted divergence from upstream supabase/postgres bundling:

- The artifact and image ship the **full PG17 extension set** — everything
  the upstream image supports (timescaledb/plv8 are PG17-incompatible
  upstream). Installed is not enabled: only the minimal
  `shared_preload_libraries` set (pg_stat_statements, pg_cron, pg_net,
  pgsodium, supabase_vault, supautils) is on by default, so the measured
  footprint is unchanged; pgaudit/pg_stat_monitor/pg_tle need a preload
  opt-in to CREATE. Disk grows accordingly (~30 -> ~250-300 MiB archive
  expected). (Preload set superseded by the shared-recipe section below:
  the bundle now ships the docker.io set.)
- `Dockerfile.artifact` is a nixos/nix flake builder producing the same
  portable rootfs as darwin (upstream's binary cache is enabled by explicit
  `--extra-substituters`/`--extra-trusted-public-keys` flags, mirroring
  `recipe.env` — the pinned flake has no `nixConfig`, so
  `--accept-flake-config` alone never enabled it); the old docker-image
  prune (`prune.sh`, `slim-entrypoint.sh`) is gone.
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
- The image smoke checks the broad preload-free set (29 creates including
  postgis/pgroonga/wrappers, a pgsodium/vault round-trip through the getkey
  wiring, and a pgvector nearest-neighbour query); the host smoke creates
  the same subset minus the getkey-dependent pair.

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
fixing both the derived image and native host use of the artifact. The
PG17-incompatible timescaledb/plv8 entries are stripped the same way
upstream's Dockerfile-17 strips them, and the build refuses the append if
the `.j2` ever grows real Jinja templating. Smokes:
the host smoke asserts the shipped template carries the allowlist; the image
smoke creates `pg_net` live as the demoted `postgres` role (the CLI
shadow-db path). Everything the appended block references exists on slim
first boot (`supabase_privileged_role` is created by the bundled
migrations); the missing `/etc/postgresql-custom/extension-custom-scripts`
path is tolerated by supautils. Drop the append once the upstream template
carries the block itself.

### Shared config recipe with the docker.io image (2026-08)

The supautils-allowlist fix above closed one drift gap; a follow-up parity
audit against the docker.io image (now built from `Dockerfile-supabase`, not
the legacy `Dockerfile-17`) found the rest: missing extension custom scripts
(no after-create grants for pg_cron/vault/pgmq…), no `conf.d`
(`pg_net.username`), a stricter pg_hba, `max_wal_senders = 0`, a fraction of
the `shared_preload_libraries` set (pgaudit/pg_tle uncreatable), and libc-C
initdb instead of ICU en_US.UTF-8. The root cause was architectural: the
bundle's config was hand-written in `nix/packages/cli-config/` while the
docker.io image copies `ansible/files/` verbatim.

The overlay's `configBundle` now consumes the SAME files the docker.io image
is built from: `postgresql.conf.j2`, `pg_hba.conf.j2`, `pg_ident.conf.j2`,
`supautils.conf.j2`, `conf.d/`, `postgresql-stdout-log.conf`,
`custom_walg.conf`, `custom_read_replica.conf`, and
`postgresql_extension_custom_scripts/`, with (a) the exact edits
`Dockerfile-supabase` applies (enable supautils/wal-g includes,
session-preload supautils, PG17 timescaledb/plv8/db_user_namespace strips)
and (b) mechanical relocation only — absolute `/etc` include targets become
PGDATA-relative names staged at first boot by `stage-shared-config.sh`
(sourced from the init script, patched at build with anchored,
asserted seds), and the file-location GUCs are commented out to follow
`postgres -D $PGDATA`. initdb runs with the docker.io image's exact flags
(`--allow-group-access --locale-provider=icu --encoding=UTF-8
--icu-locale=en_US.UTF-8`). The libc `lc_*` side cannot use nix glibc's
`LOCALE_ARCHIVE` mechanism — the portable binaries are relinked to the
SYSTEM glibc, which ignores it (first CI run failed exactly there) — so the
slim image generates a system locale archive with the base image's own
Debian `localedef` and sets `LANG`/`LC_ALL` like Dockerfile-supabase, while
`stage-shared-config.sh` probes with the real `postgres -C` binary and
appends an `lc_* = 'C'` fallback on hosts that cannot resolve the locale
(database collation stays ICU-provider either way).

`nix/packages/local-dev.conf` is the single, complete list of deliberate
divergences (loopback/54322 native contract, `/tmp` socket, low-footprint
profile); `entry.sh` shrinks to the two docker overrides (listen/port).
pg_hba carries one adaptation: `peer map=supabase_map` becomes `trust` —
the map assumes the docker.io image's OS users, and it resolves them to
full role access anyway, so single-OS-user environments get the same
effective posture. Trade-offs accepted for parity: the full docker.io
preload set replaces the minimal one (a few MB RSS), and fresh databases are
ICU en_US.UTF-8 like production instead of libc C. The image smoke verifies
the recipe live (conf.d, replication slots, loopback trust, ICU provider,
custom-script grants via non-superuser creates of pg_cron/vault, pgaudit +
pg_tle creates); the host smoke asserts the shipped files. Drop the overlay
once upstream's `cli-config` assembles from `ansible/files/` itself.

## CLI Image-Gap Closure (2026-08)

Dogfooding the slim stack in supabase/cli surfaced gaps vs the docker.io
image (supabase/slim-services#280):

- `pg_dumpall` joins the portable artifact's binary set and `uniq` the
  image's busybox applets: `db dump --role-only` pipes
  `pg_dumpall | ... | uniq` inside the container and was broken on slim.
  Both smokes now exercise the role-only path (the image smoke runs the
  pipeline in-container).
- Local-dev `max_connections` raised 50 → 100 (docker.io parity):
  supavisor's default meta pool alone is 25, and the halved budget forced
  the CLI to carry a slim-only `DB_POOL_SIZE=5`. Unused slots cost a few KB
  of shared memory each; the low-footprint profile keeps every other value.
  The image smoke asserts the new value.

## Differential docker.io parity smoke (2026-08)

The image smoke previously pinned individual recipe expectations
(`pg_net.username`, `max_wal_senders`, locale, …). Those pins encode the
recipe of ONE upstream version and break on force-rebuilds of older tags:
17.6.1.106 has no `conf.d/pg_net.conf` upstream, so its docker.io image
does not set `pg_net.username` either and the hardcoded check could never
pass there — despite the slim image being in perfect parity with its own
upstream version.

The smoke now boots `public.ecr.aws/supabase/postgres:$VERSION` (the mirror
dodges Docker Hub pull limits) next to the slim container and requires the
two servers to be identical: full `pg_settings`, `pg_dumpall --globals-only`
(roles and attributes), the schema of `postgres` and `template1`,
`pg_available_extensions`, database encodings/locales, and the host
`pg_hba_file_rules`. Both sides are captured with the slim image's own
client binaries so client-version skew cannot leak into the diff, and the
phase runs before any mutating check.

Intentional divergences are one explicit allowlist in the smoke: the
local-dev profile GUCs (`local-dev.conf`), bundle/layout paths, and buffers
postgres derives from `shared_buffers`. Socket-local pg_hba rules are also
excluded (distroless has no OS user database for peer auth; host rules must
match). Everything else must equal the upstream image of the same version,
so version-specific recipe content (conf.d, supautils allowlist, hba, ICU
initdb, migrations) is compared against the right baseline automatically.
The subsumed hardcoded checks are gone; behavioral contracts (role-only
dump pipeline, non-superuser CREATE EXTENSION, replication slot,
passwordless loopback) stay.
