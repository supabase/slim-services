# CLI Image-Gap Closure Plan

Plan for closing the image-family gaps surfaced by CLI dogfooding
(supabase/cli slim-stack integration). Scope rule, applied throughout:

> If the slim image cannot run the docker.io command (no `pg_dumpall`, no
> shell, baked entrypoint, non-root `/root`), that is an image-family gap —
> close it here or keep a locked CLI exception. If the image *can* do the job
> but the CLI skips it, passes the wrong argv, or runs it too late, that is a
> CLI bug and stays in supabase/cli.

Each item below removes a CLI special case once shipped. Items are ordered by
CLI unblock value over implementation effort.

## PR 1 — quick wins (config + small binary additions)

### 1. `pg_dumpall` + `uniq` in the postgres image (`db dump --role-only`)

The CLI's role-only dump script needs `pg_dumpall` and `uniq`; the slim
postgres image has `pg_dump`, `bash`, and `sed` but neither of those two.
Until this ships, the CLI keeps the role-only job on docker.io postgres.

- Add `pg_dumpall` to the artifact binaries list in
  `services/postgres/nix/packages/postgres-portable.nix` (the
  `binaries="postgres pg_config pg_ctl initdb psql pg_dump pg_restore …"`
  line). It is a small libpq client binary; the existing dependency-copy and
  rpath machinery handles it with no other changes. It also lands in the
  host-native artifact, which is correct — the CLI's native runtime needs it
  for the same command.
- Add `uniq` to the busybox applet symlink list in
  `services/postgres/Dockerfile.slim` (the `for applet in sh basename cat …`
  loop). busybox ships the applet; this is one word. `uniq` is a coreutils
  concern, not a postgres one, so it belongs in the image toolbox rather
  than the artifact (hosts already have coreutils).
- Extend `services/postgres/smoke.sh`: assert `pg_dumpall --version` succeeds
  in-container and `uniq` resolves, so a future prune can't silently regress
  the CLI contract. Ideally exercise the actual role-only pipeline (`pg_dumpall
  --roles-only | … | uniq`) against the initialized database.
- CLI follow-up once published: delete the role-only docker.io exception and
  bump the image pin.

### 2. Stop baking `IMAGE_TRANSFORMATION_ENABLED=false` in storage

`services/storage/runtime.env` bakes `IMAGE_TRANSFORMATION_ENABLED=false` as
image ENV. storage-api prefers that key over the legacy
`ENABLE_IMAGE_TRANSFORMATION` the CLI sets, so the baked `false` silently wins
even when the user enables imgproxy. docker.io bakes no such default.

- Delete the line from `services/storage/runtime.env` (and the corresponding
  bullet in `services/storage/REPORT.md`). Behavior with no env set is
  upstream's own default, same as docker.io.
- Keep `NODE_OPTIONS` and `DATABASE_MAX_CONNECTIONS`: those are pure
  footprint tuning with no cross-key precedence trap, and the CLI does not
  set competing values.
- CLI keeps setting both keys explicitly either way; this just removes the
  image's ability to override the user's choice.

### 3. Raise `max_connections` to 100 (docker.io parity)

`services/postgres/nix/packages/local-dev.conf` sets `max_connections = 50`;
docker.io ships 100 and supavisor's default meta pool alone is 25, so 50
forces the CLI to carry a slim-only `DB_POOL_SIZE` divergence.

- Change `max_connections = 50` → `100` in the divergence block (one line,
  with the comment noting it restores docker.io parity for pooler headroom).
- Decision rationale: the fixed cost of unused connection slots is a few KB
  of shared memory each — negligible next to the profile's `shared_buffers`
  and cache settings, which stay. Real memory is only spent when backends
  actually connect, and a 25-stack host was never going to survive 25×100
  live backends on either setting. Parity is worth more than the theoretical
  budget: it deletes a CLI special case and un-falsifies the CLI's
  "flag-off is byte-identical" claim.
- Update `services/postgres/REPORT.md` (it documents the 50) and re-run the
  smoke's RSS measurement to confirm the idle-footprint delta is noise.

### 4. Create `/mnt` in the storage image (volume mount parity)

docker.io stacks mount the file-backend volume at `/mnt`; the slim image has
no `/mnt`, so Docker auto-creates the mountpoint root-owned and uid 65532
cannot write it. The CLI currently diverges to `/home/nonroot`.

- Create `/mnt` owned by `65532:65532` in `services/storage/Dockerfile.slim`.
  Two hazards, both already learned on the `/home/nonroot` 0711 fix
  (see the `chmod /home/nonroot via a RUN diff layer` history):
  - If the distroless base already ships `/mnt`, `COPY --chown` onto an
    existing directory merges contents but keeps the base's metadata — use
    the busybox `RUN` diff-layer pattern instead. The stage runs as nonroot,
    which cannot chown a root-owned directory, so that path needs a
    `USER 0` … `USER nonroot` round-trip around the one RUN.
  - If the base does not ship it (expected for
    `gcr.io/distroless/base-debian13`), the postgres `pgdata-skel` pattern
    works: `COPY --from=tools --chown=65532:65532 /mnt-skel/ /mnt/`.
  Verify which case holds during implementation; either way the image smoke
  must assert `/mnt` is uid 65532 (mode 0755 — sidecars like imgproxy run as
  another uid and need to traverse into it, same reasoning as the
  `/home/nonroot` 0711 fix).
- Explicit non-goal: fixing ownership of a volume *already initialized* by a
  docker.io run stays a CLI migration concern
  (`legacyIsVolumeAccessibleToImage` fail-fast). The image only guarantees a
  fresh volume seeds correctly.
- Keep `/home/nonroot` working as it does today — the CLI can switch its
  mount path back to `/mnt` on its own schedule after this ships.

## PR 2 — exec-form HEALTHCHECKs (auth, pgmeta, studio, storage)

Distroless/scratch images cannot run the CLI's `CMD-SHELL` healthchecks, so
the CLI currently reports "ready on Running" for auth/studio/pg-meta. Docker
uses an image-baked `HEALTHCHECK` whenever the CLI omits `--health-cmd`, so
baking exec-form probes makes the CLI's host/Kong probes optional and closes
the gap for every consumer, not just the CLI.

- Node images (`services/pgmeta`, `services/studio`, `services/storage`
  Dockerfile.slim) bundle `/node/bin/node`, so the probe is free:

  ```dockerfile
  HEALTHCHECK --interval=5s --timeout=5s --retries=10 --start-period=30s \
    CMD ["/node/bin/node", "-e", \
         "fetch(`http://127.0.0.1:${process.env.PG_META_PORT||8080}/health`).then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]
  ```

  Exec form cannot expand env vars, but `node -e` reads `process.env`
  itself, so the port stays override-safe. Endpoints must mirror what the
  CLI probes today: pgmeta `/health`, storage `/status`, studio its profile
  health endpoint (confirm the exact path against the CLI's docker.io
  healthcheck for the pinned studio version during implementation).
- Auth (`services/auth/Dockerfile.slim`) is a static Go binary on `scratch` —
  nothing in the image can make an HTTP request. First check whether the
  pinned gotrue exposes a native healthcheck invocation; assuming it does
  not, ship a tiny static probe helper: a `CGO_ENABLED=0` Go binary (GET a
  URL, exit 0 on 2xx, else 1) cross-compiled by `services/auth/build-host.sh`
  alongside `bin/auth` (the build is already a host Go cross-compile, so
  this adds no new toolchain). ~1 MiB, no shell, no busybox — a static
  busybox `wget` would also work but reintroduces an entire toolbox into a
  scratch image, which fights the slim design. The helper is reusable for
  any future scratch-based service.
- Choose generous `--start-period` per service (studio is the slowest;
  postgres first boot runs initdb + migrations and should get 60s+ if we
  extend this to postgres later — not required by the CLI gap, which names
  auth/studio/pg-meta and ideally storage).
- Smokes: assert `docker inspect` reports the container reaching `healthy`,
  not just the endpoint returning 200 — that is the contract the CLI relies
  on.
- CLI follow-ups once published: drop the Kong/host readiness probes (auth
  first), keep `--health-cmd` omitted so the image HEALTHCHECK governs.

## Explicitly not closing (fights the slim design)

- **No shell in edge-runtime.** The CLI carries the exception.
- **No world-traversable `/root`.** The CLI mounts eszips and deno cache
  under `/tmp` or the writable home instead — that is a CLI argv/mount fix.
- **No realtime tenant migrations in the postgres bundle.** Realtime's
  one-shot migrate/seed before user migrations is a CLI ordering fix; the
  slim realtime `entry.sh` already migrates/seeds then `exec "$@"`.
- **No publishing of historical tags.** slim-services publishes the current
  pins forward; the CLI translates only the current Dockerfile pin (or a
  known published set) and keeps `.temp/*` historical pins on docker.io.

## Sequencing

1. **PR 1** (this branch): items 1–4. Small, independent, each deletes or
   unblocks deleting a CLI exception. Re-run the affected service builds +
   smokes (`postgres`, `storage`) on the current platform matrix, then
   `scripts/update-results-tables.sh` if sizes moved.
2. **PR 2**: HEALTHCHECKs. Needs per-service endpoint confirmation and the
   auth probe helper, so it ships separately rather than holding up PR 1.
3. **Publish + notify CLI**: after each PR's images publish, the CLI deletes
   the matching exception (role-only dump exception, slim-only
   `DB_POOL_SIZE`, host readiness probes, `/home/nonroot` storage mount
   path).
