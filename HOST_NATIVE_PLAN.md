# Host-Native Artifact Plan

Goal: every Supabase-owned service ships a **self-contained, relocatable
archive** that the CLI can download to `~/.supabase/bin/<service>/<version>/`
and run directly under its process manager (process-compose) — **no Docker**.
Primary target: `darwin-arm64` (the 25-parallel-stacks-on-macOS goal).
Secondary: `linux-arm64`/`linux-amd64` host-native (CI runners, Linux laptops).

This document is an implementation handoff. Work the phases in order; each
service section lists concrete steps, files, and acceptance criteria. The
repo's existing Docker-image outputs stay unchanged — host-native is a second
packaging of the same per-service artifact pipeline, not a replacement.

## Where we are today

Only **edge-runtime** meets the bar. It is the reference implementation:
Nix-built, bundles every library except the host libc, darwin-arm64 supported,
smoke-testable as a plain host process.

| Service | Built with | Self-contained? | darwin-arm64? | Gap class |
|---|---|---|---|---|
| edge-runtime | Nix | yes (all libs except host libc) | **yes** | none — reference |
| auth | Go in Docker | yes (static binary) | no (repo); CLI uses upstream releases | trivial cross-compile |
| postgrest | image extraction + ELF closure | mostly (linux) | no (repo); upstream publishes macOS builds | static Nix build exists as experiment |
| realtime | mix release in Docker | **no** — deletes libc/libssl/libstdc++, expects distroless base | no | BEAM Nix build |
| analytics | mix release in Docker | **no** — same pattern | no | BEAM Nix build |
| pooler | mix release in Docker | **no** — same pattern | no | BEAM Nix build |
| storage | Node build in Docker | **no** — JS bundle only, Node from base; Linux-built Sharp | no | needs a Node runtime story |
| pgmeta | Node build in Docker | **no** — JS bundle only | no | needs a Node runtime story |
| studio | Node build in Docker | **no** — JS bundle + Linux native deps | no | out of scope (see Non-goals) |
| postgres | upstream image prune | self-contained but **not relocatable** (absolute `/nix/store` paths) | separate CLI binary distribution exists | delegate (see §7) |

Existing machinery to build on (read these first):

- `NIX_PORTABLE_ARTIFACT_PLAYBOOK.md` — the reusable pattern: base/dylib
  selection, closure completion, rpath/install-name rewriting, ad-hoc signing,
  audit. Written from the edge-runtime work; this plan generalizes it.
- `CI_MATRIX.md` — target naming (`darwin-arm64`, `linux-arm64`,
  `linux-amd64`), runner requirements, per-target commands.
- `scripts/build-artifact-from-nix.sh` — local Nix runner (darwin) + Docker
  runner (linux-on-macOS); `NIX_PACKAGE_OVERLAY` mechanism for repo-owned
  package files; `scripts/portable-darwin-fixup.sh`,
  `scripts/audit-portable-artifact.sh`, `scripts/collect-elf-deps.sh`,
  `scripts/patch-elf-rpaths.sh`.
- `services/edge-runtime/` — recipe (`ARTIFACT_BACKEND="nix"`,
  `SUPPORTS_DIRECT_ARTIFACT_SMOKE="true"`), `nix/edge-runtime.nix` overlay,
  smoke with a host-process branch (`ARTIFACT_ROOTFS=` mode).
- `services/<service>/runtime.env` — the low-footprint runtime profile per
  service. For Docker it is baked as ENV; **for host-native the CLI applies
  the same file as process environment**. Keep it the single source of truth.

## The host-native artifact contract

Define once, then hold every service to it:

1. Layout: `artifacts/<service>/<version>/<os>-<arch>/rootfs/` containing
   `bin/<service>` (a wrapper or the binary itself) plus everything it needs.
   Distribution archive `<service>-<version>-<os>-<arch>.tar.zst`.
2. **Relocatable**: no absolute paths into the build machine or `/nix/store`;
   libraries resolved relative to the wrapper (`$ORIGIN`/`@loader_path` or the
   wrapper exporting `LD_LIBRARY_PATH`/`DYLD_LIBRARY_PATH`, as edge-runtime
   does). `scripts/audit-portable-artifact.sh` must pass.
3. Only host dependencies allowed: libc family on Linux
   (see `should_exclude` in `services/edge-runtime/nix/edge-runtime.nix`),
   the system frameworks/libSystem on macOS.
4. `manifest.json` gains `"portable": true|false` and, when true, the list of
   assumed host libraries — so the CLI can verify before running. Add this to
   the manifest writers once, in the shared scripts.
5. Smoke: `SUPPORTS_DIRECT_ARTIFACT_SMOKE="true"` in the recipe and a host-
   process branch in `services/<service>/smoke.sh` (edge-runtime's
   `ARTIFACT_ROOTFS=` branch is the template). On darwin this is the ONLY
   smoke (no Docker image is produced), so it must cover real functionality,
   not just `--help`.
6. Runtime profile: the smoke's host branch must apply
   `services/<service>/runtime.env` to the process environment, mirroring what
   the CLI will do.

## Phase 0 — Contract plumbing (do first, small)

- Add the `portable` field + assumed-host-libs to manifest generation
  (`build-artifact-from-nix.sh`, `build-artifact-from-source.sh`).
- Add a tiny shared helper to `scripts/smoke-lib.sh` for host-process smokes:
  start command with `runtime.env` applied, wait for TCP/HTTP readiness, kill
  on exit, and record RSS/CPU via `ps -o rss=`/`ps -o %cpu=` (docker stats is
  unavailable for host processes; keep the same
  `SLIM_RUNTIME_METRICS_FILE` JSON shape so manifests stay uniform).
- Acceptance: edge-runtime darwin build (`TARGET_OS=darwin ARCH=arm64
  scripts/ci-build-service.sh edge-runtime <version>`) produces a manifest
  with `portable: true` and host-process runtime metrics.

## Phase 1 — auth (P0: proves the end-to-end path, ~a day)

Go cross-compiles trivially; this establishes the full
archive → download-layout → run-on-mac loop with minimal build risk.

- `services/auth/Dockerfile.artifact`: the builder already sets
  `GOOS=${TARGETOS} GOARCH=${TARGETARCH}` with `CGO_ENABLED=0`. Add a darwin
  path: when `TARGET_OS=darwin`, run the same build with `GOOS=darwin` —
  either in Docker (Go cross-compiles darwin from linux) or via a small
  `build-artifact-from-source` darwin branch. Output rootfs:
  `bin/auth` (+`gotrue` symlink) and the CA bundle is NOT needed on macOS
  (system trust store) — verify GoTrue's TLS paths use the Go defaults.
- Recipe: `SUPPORTS_DIRECT_ARTIFACT_SMOKE="true"`.
- Smoke: host-process branch — start `bin/auth` against the harness postgres
  (which may still run in Docker on the dev machine; that's fine, the service
  under test is the host process), assert `/health`, record metrics.
- Acceptance: `TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh auth
  <version>` on a Mac produces `auth-<version>-darwin-arm64.tar.zst`; untar
  anywhere, `bin/auth` serves `/health`. Compare layout with what the CLI
  already expects under `~/.supabase/bin/auth/<version>/darwin-arm64/`.

## Phase 2 — postgrest (P1)

- Preferred: promote `services/postgrest/nix/static-v14_10-arm64.nix` from
  experiment to the recipe's darwin/static path (update to the current
  pinned version; the recipe already carries `NIX_*` scaffolding with
  `NIX_STATUS`/`NIX_ATTR=postgrestStatic`). Static binary → same contract as
  auth.
- Fallback if the Nix static build fights back: consume upstream's published
  macOS binaries (`ARTIFACT_BACKEND` gains a small `github-release` fetcher)
  — less pure but unblocks the CLI path; note it in REPORT.md either way.
- Smoke: host-process branch against harness postgres, `/` returns 200 with
  `PGRST_DB_POOL=2` from runtime.env applied.

## Phase 3 — BEAM trio: realtime, analytics, pooler (P1, the real work)

This is where the Nix playbook earns its keep. One pattern, three services;
do **realtime first** (most valuable per-stack), then clone for the others.

- Write `services/realtime/nix/realtime.nix` following
  `NIX_PORTABLE_ARTIFACT_PLAYBOOK.md`: build the mix release with
  `beamPackages`/`mixRelease` (Erlang/Elixir versions from
  `services/realtime/Dockerfile.artifact` args), include ERTS, then the
  portable packaging steps: bundle every shared lib EXCEPT host libc
  (openssl, ncurses, zlib, libstdc++ — the exact libs the Docker artifact
  currently deletes), rewrite rpaths, darwin dylib fixup + ad-hoc sign.
  `sources/realtime` is read-only — the package lives in `services/*/nix/`
  and is applied via `NIX_PACKAGE_OVERLAY` or built directly with
  `NIX_FLAKE`/`NIX_EXPRESSION` pointing at repo-owned files.
- NIF inventory first (fast fail): grep each release's `lib/*/priv` for `.so`
  after a Docker build to know exactly which native artifacts must compile on
  darwin. Realtime and supavisor both use libcluster/postgrex-class deps that
  are pure BEAM, but check bcrypt/crypto NIFs explicitly.
- Recipe: keep `ARTIFACT_BACKEND="docker-source"` for linux images; add the
  nix path for darwin (`NIX_STATUS="candidate"` → promote when smoked). The
  pooler recipe already declares `NIX_STATUS="candidate"` and its REPORT
  mentions the upstream Nix flake as a lead — check supavisor upstream for a
  flake to reuse before writing one.
- Keep the BEAM runtime profile identical: the host smoke exports
  `ELIXIR_ERL_OPTIONS` etc. from `runtime.env` (single scheduler, no
  busy-wait — matters even more when 25 stacks share a laptop without
  cgroups).
- Smoke: host-process branch reusing the existing env from each image smoke
  (`/healthcheck` for realtime, `/health` for analytics, `/api/health` for
  pooler) against harness postgres.
- Acceptance per service: darwin-arm64 archive; untar + run under the smoke;
  `audit-portable-artifact.sh` clean; metrics recorded.

## Phase 4 — Node duo: storage, pgmeta (P2, decide the runtime story first)

**Decision (2026-07-07): Option A — one shared Node runtime.** The service
artifacts stay JS bundles plus a thin `bin/<service>` wrapper that resolves
the runtime in order: `$SUPABASE_NODE` → `../../node/bin/node` relative to the
artifact (the CLI's shared runtime location) → `node` on `PATH`. The manifest
records the requirement in `runtime_requires` (e.g. `node>=20`), so the CLI
can verify before running. The shared runtime itself is the official
Node.js darwin-arm64 tarball (signed by the Node release team) downloaded by
the CLI — this repo does not repackage Node. Smokes provide the runtime via
`SUPABASE_NODE` (pinned via nixpkgs) so the round-trip is validated against
the same major each service's Docker image uses (pgmeta 20, storage 24).
Option B (bundle Node per service) was rejected for the ~50 MiB duplication
per service; Option C (bun compile) for compat risk with native modules.

Original decision framing:

- **Option A (recommended): one shared Node runtime.** The CLI downloads a
  single `node-<version>-darwin-arm64` runtime artifact; storage and pgmeta
  artifacts stay JS-bundles + `bin/<service>` wrapper that resolves
  `SUPABASE_NODE` (or a relative `../node/bin/node`). Smallest total download,
  one security-patch surface. Requires the Node-major convergence follow-up
  (pgmeta 20 / studio 22 / storage 24 today — check engine ranges).
- Option B: bundle Node per service (Nix `nodejs` closure through the
  playbook) — self-contained but ~50 MiB duplicated per service.
- Option C: `bun build --compile` single binaries — attractive, but a runtime
  swap with real compat risk (storage uses Sharp/native modules); only pilot
  behind a smoke.
- Native modules: storage's Sharp must be built per-platform. For local dev
  the slim profile already sets `IMAGE_TRANSFORMATION_ENABLED=false`; the
  darwin artifact can exclude Sharp and document the limitation (same
  philosophy as edge-runtime's no-AI profile).
- Smoke: host-process branches; storage runs the full bucket/upload/download
  round-trip on the file backend.

## Phase 5 — Distribution hygiene (P2, before anything ships to users)

- **Signing**: `portable-darwin-fixup.sh` ad-hoc signs — enough for local
  smokes, not for distribution. Scope a Developer ID + notarization step
  (likely in CI, on the darwin runners; keep it out of local dev loops).
- **CI**: extend `.github/workflows/` per `CI_MATRIX.md` — darwin-arm64
  runners build + smoke + upload archives for each promoted service
  (edge-runtime's workflow is the template; it already uploads
  `.tar.zst` artifacts).
- **Checksums**: publish `SHA256SUMS` next to archives so the CLI can verify
  downloads.

## Non-goals

- **studio** host-native: heaviest Node service, Linux native deps, and it is
  disabled by default in the minimal stack — keep it Docker-only (or a shared
  singleton at the CLI level).
- **postgres** relocatable artifact from this repo: the pruned rootfs is
  wired to absolute `/nix/store` paths by design. The CLI's existing darwin
  postgres binary distribution (`~/.supabase/bin/postgres/<version>/`) is the
  host-native vehicle; its real blocker is **extension parity** (pgvector is
  missing from that distribution today — file/track upstream with the
  supabase/postgres team). Revisit only if that distribution is abandoned.
- CLI-side integration (process-compose wiring, download/verify UX, port
  allocation) — separate repo (`supabase/cli`); this repo's deliverables end
  at "archive + manifest + smoke that proves it runs on the host".
- linux host-native packaging beyond what the artifacts already provide —
  typical glibc hosts can run the linux artifacts; formalize only if the CLI
  targets Docker-less Linux.

## Suggested execution order for the implementing session

1. Phase 0 (contract plumbing) — everything else depends on the host-smoke
   helper and manifest field.
2. Phase 1 auth — smallest end-to-end proof; validates archive layout against
   the CLI's `~/.supabase/bin` expectations.
3. Phase 3 realtime — the hard one; do it while context is fresh, then clone
   the pattern to analytics and pooler.
4. Phase 2 postgrest (can interleave — independent of Phase 3).
5. Phase 4 decision + storage/pgmeta.
6. Phase 5 CI + signing once two or more services are promoted.

Verification for every service: `TARGET_OS=darwin ARCH=arm64
scripts/ci-build-service.sh <service> <version>` on a Mac must build, smoke as
a host process (with runtime.env applied), audit clean, and record runtime
metrics in the manifest — then untar the archive into a scratch directory and
run the same smoke against it to prove relocatability.
