# CLI Image-Gap Closure Plan

Plan for closing the image-family gaps surfaced by CLI dogfooding
(supabase/cli slim-stack integration).

> **Status (2026-08-27): implemented.** All five hard-gate items shipped in
> one PR; each service's `REPORT.md` (2026-08 sections) records what changed
> and how the smokes pin it. Remaining before the CLI follow-ups can merge:
> publish and the CLI pin bump.

Scope rule, applied throughout:

> If the slim image cannot run the docker.io command (no `pg_dumpall`, no
> shell, baked entrypoint, non-root `/root`), that is an image-family gap —
> close it here or keep a locked CLI exception. If the image *can* do the job
> but the CLI skips it, passes the wrong argv, or runs it too late, that is a
> CLI bug and stays in supabase/cli.

## Hard gates: what the CLI is waiting on

The CLI carries no interim workarounds for these (no docker.io role-dump
exception, no Kong/host readiness probes). Each row is a hard gate: the
matching CLI follow-up merges only once the slim image is published and the
CLI's Dockerfile pin can see it — until then the listed degradation is live
on slim stacks.

| slim-services deliverable | Gated CLI change | Behavior until it lands |
|---|---|---|
| postgres: `pg_dumpall` + `uniq` in the image | `db dump --role-only` runs on the slim image | Role dumps stay broken on slim |
| auth, studio, pg-meta, storage: exec-form `HEALTHCHECK` | CLI keeps omitting `--health-cmd`; Docker uses the image probe | Slim `start` reports ready on `Running` |
| storage: `/mnt` owned by uid 65532 | CLI remounts slim storage at `/mnt` (one path with docker.io) | CLI keeps mounting at `/home/nonroot` |
| storage: no baked `IMAGE_TRANSFORMATION_ENABLED=false` | CLI relies on its existing dual-key set from config | Transforms stay silently off if anyone drops those env keys |
| postgres: local-dev `max_connections` = 100 | CLI reverts the unconditional `DB_POOL_SIZE=5` in `supavisor.service.ts` | Keep a slim-only pool cap, or the pooler is unbootable under a full stack |

CLI changes with no image gate (ship independently of this repo, listed for
cross-reference only): gen types argv, functions `/root` → `/tmp` mounts,
realtime one-shot before user migrations, current-pin-only version
translation, storage volume write probe, SIDE_EFFECTS cleanup.

## Explicitly not closing (fights the slim design)

- **No storage `migrate-call.js` (or equivalent one-shot migrate entry).**
  The CLI keeps its storage migration one-shot on docker.io; the slim image
  only needs to serve.
- **No shell in edge-runtime.** The CLI carries the exception.
- **No world-traversable `/root`.** The CLI mounts eszips and deno cache
  under `/tmp` or the writable home instead — that is a CLI argv/mount fix.
- **No realtime tenant migrations in the postgres bundle.** Realtime's
  one-shot migrate/seed before user migrations is a CLI ordering fix; the
  slim realtime `entry.sh` already migrates/seeds then `exec "$@"`.
- **No publishing of historical tags.** slim-services publishes the current
  pins forward; the CLI translates only the current Dockerfile pin (or a
  known published set) and keeps `.temp/*` historical pins on docker.io.
