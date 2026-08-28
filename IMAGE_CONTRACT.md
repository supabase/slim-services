# Image identity contract

Slim images for postgres, storage, and edge-runtime must be interchangeable
with the live docker.io pin for leftover named volumes and CLI-shaped
start. Numbers are never committed here — they are generated from the pin
at image-build time.

## Pin

Each identity-contract service sets `SOURCE_IMAGE_DIGEST` and
`IDENTITY_SOURCE_TAG` in `recipe.env`. `UPSTREAM_IMAGE` uses
`${VERSION:-$SOURCE_REF}` so pin selection follows the released tag
(release CI sets `VERSION` and overwrites `SOURCE_REF`). The digest
belongs to `IDENTITY_SOURCE_TAG`, not to `SOURCE_REF`. Introspection,
image build, and smokes pull `tag@digest`. A missing digest or a failed
pull is a hard error. When the image tag is not `IDENTITY_SOURCE_TAG`,
that tag's index digest is resolved — the committed digest is not reused
across versions. There is no ECR-first fallback.

`SKIP_UPSTREAM_IDENTITY=1` is rejected for identity-contract image builds
and image smokes. Never invent uid/gid/mode as a substitute for the pin.
Storage `/mnt` is the one exception: invent `0:0:755` only when the path
is absent and the pin starts as root. If the path exists but `stat`
failed, fail. A `test -e` status other than 0 or 1 is a probe failure,
not "absent".

## Generation

`scripts/introspect-upstream-identity.sh` (and `scripts/identity-lib.sh`)
pull the digest, then probe the pin:

1. `Config.User` (empty means root).
2. Owner/mode of the CLI mount path on the image filesystem (`stat` via a
   bind-mounted busybox so the pin does not need a shell).
3. The `/etc/passwd` / `/etc/group` lines for that owner.

Those values become Docker `ARG`s. `scripts/render-dockerfile.sh` stays
append-only for `runtime.env` — it does not rewrite `COPY --chown`.

## Service policy

- **Start user** matches the pin. Empty `Config.User`, `0`, and `root`
  are the same (euid 0): docker.io leaves USER unset; distroless's root
  variant bakes `USER 0`.
- **postgres** starts as root, then drops to the probed owner before
  `postgres` execs. `docker-entrypoint.sh` is the image `ENTRYPOINT` and
  follows official argv rules: empty / leading `-` stays the server path
  (`postgres -D /etc/postgresql`); any other argv is `exec`'d as-is so
  `db dump` / `db pull` (`bash -c`) do not initdb. First boot runs
  `/docker-entrypoint-initdb.d` (`.sh` / `.sql`) in the temp-server window
  after bundle initdb. When that directory already has `migrate.sh` (CLI
  `--from-backup` overwrite), skip the bundle copy so restore replaces
  image migrations. The shim uses busybox-`su`, not extracted upstream
  `gosu`. Cluster files stay in `PGDATA`.
  `/etc/postgresql/postgresql.conf` sets `data_directory` /
  `hba_file` / `ident_file` at `PGDATA`, includes the bundle recipe (not
  leftover initdb conf), and stays root-writable for CLI `>>` / `>` writes.
- **storage** and **edge-runtime** stay root. Seed `/mnt` and `/root` from
  the probe. Ship `wget` (storage) and `sh` (edge-runtime) unconditionally
  because the CLI always uses them. Storage ships `dist/scripts/migrate-call.js`
  (third Rolldown input) plus `postgres-migrations`'
  `0_create-migrations-table.sql` beside that script. Empty `ENTRYPOINT` and
  `CMD ["/node/bin/node","dist/start/server.js"]` so default `docker run`
  still serves, while `docker run IMAGE node dist/scripts/migrate-call.js`
  is the CLI one-shot (`node` is on `PATH`). A node `ENTRYPOINT` would turn
  that argv into `node node …`.

Do not extract upstream `docker-entrypoint.sh` or `gosu`. Do not root a
stateless service that the pin does not start as root.

## Smoke

Pairwise image smokes pull the same digest the build used. They fail
closed on pull miss. They assert identity (USER + mount owner/mode),
leftover volumes in both directions, and a CLI-shaped start for postgres
(`docker-entrypoint.sh postgres -D /etc/postgresql`, plus an `initdb.d`
marker, a `--from-backup` overwrite of `initdb.d/migrate.sh` that must
skip the bundle copy, and a foreign-argv `id` that must not initdb).
Storage leftover also checks that the imgproxy pin's `Config.User` can
read objects on `/mnt`. Edge leftover write/read of `/root` runs inside
the pin (`run_in_pin` with the named volume mounted). Static busybox is
only that container's entrypoint when the pin has no shell — not a
separate image.
