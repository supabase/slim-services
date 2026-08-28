# Image identity contract

Slim images for postgres, storage, and edge-runtime must be interchangeable
with the live docker.io pin for leftover named volumes and CLI-shaped
start. Numbers are never committed here — they are generated from the pin
at image-build time.

## Pin

Each identity-contract service sets `SOURCE_IMAGE_DIGEST` and
`IDENTITY_SOURCE_TAG` in `recipe.env`. The digest belongs to that tag,
not to `SOURCE_REF` (release CI overwrites `SOURCE_REF` to `VERSION`).
Introspection, image build, and smokes pull `tag@digest`. A missing
digest or a failed pull is a hard error. When the image tag is not
`IDENTITY_SOURCE_TAG`, that tag's index digest is resolved — the
committed digest is not reused across versions. There is no ECR-first
fallback.

`SKIP_UPSTREAM_IDENTITY=1` is rejected for identity-contract image builds
and image smokes. Never invent uid/gid/mode as a substitute for the pin.

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
  `postgres` execs. `docker-entrypoint.sh` is a busybox-`su` shim so the
  CLI can `exec docker-entrypoint.sh postgres -D /etc/postgresql`. Cluster
  files stay in `PGDATA`. `/etc/postgresql/postgresql.conf` sets
  `data_directory` / `hba_file` / `ident_file` at `PGDATA`, includes the
  bundle recipe (not leftover initdb conf), and stays root-writable for
  CLI `>>` / `>` writes.
- **storage** and **edge-runtime** stay root. Seed `/mnt` and `/root` from
  the probe. Ship `wget` (storage) and `sh` (edge-runtime) unconditionally
  because the CLI always uses them.

Do not extract upstream `docker-entrypoint.sh` or `gosu`. Do not root a
stateless service that the pin does not start as root.

## Smoke

Pairwise image smokes pull the same digest the build used. They fail
closed on pull miss. They assert identity (USER + mount owner/mode),
leftover volumes in both directions, and a CLI-shaped start for postgres
(`docker-entrypoint.sh postgres -D /etc/postgresql`). Storage leftover
also checks that the imgproxy pin's `Config.User` can read objects on
`/mnt`. Edge leftover write/read of `/root` runs inside the pin
(`run_in_pin` with the named volume mounted). Static busybox is only
that container's entrypoint when the pin has no shell — not a separate
image.
