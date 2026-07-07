# Footprint Reduction Plan — Image Size, RAM, and CPU

Goal: make every image in the local stack as small as possible on **three axes — compressed
image size, resident memory (RSS), and idle/steady-state CPU** — so ~25 parallel stacks fit
on a 32 GB macOS machine. Phase 1/2 of this repo attacked disk size (1777 MiB → 470 MiB
compressed). This plan is the next pass: it adds the RAM/CPU axes, onboards postgres (the
largest untouched image), and details the remaining disk work per service. Scope is limited
to **Supabase-owned services**; third-party images (kong, imgproxy, vector, mailpit) are
deferred (§1.2).

This document is an implementation handoff. Each service section lists concrete actions,
the files to touch, and acceptance criteria. Work top-to-bottom within a priority band;
sections are independent unless noted.

Key sizing fact that shapes priorities: Docker stores image layers **once**, shared across
all containers of all stacks — image size does *not* multiply by 25. RSS and CPU *do*.
Therefore runtime actions (RAM/CPU) outrank further disk shaving on already-slim images.

---

## 0. Cross-cutting prerequisites (do these first)

### 0.1 Measure RSS and idle CPU in the pipeline (P0 — everything else is judged by this)

Today `scripts/measure-artifact.sh` records only sizes. Extend the pipeline so every
service build also records runtime cost:

- After the smoke test passes, keep the container running, wait ~30 s for steady state,
  then sample `docker stats --no-stream` (and `/sys/fs/cgroup` inside if needed).
- Record in `artifacts/<service>/manifest.json`: `runtime_rss_bytes`, `idle_cpu_pct`
  (average over ≥10 s), alongside the existing size fields.
- Files: `scripts/measure-artifact.sh`, `scripts/smoke-lib.sh`, `scripts/smoke.sh`,
  `scripts/ci-build-service.sh` (call order: build → smoke → measure-runtime → archive).
- Add the two new columns to `SLIM_IMAGES_REPORT.md` and each `services/<svc>/REPORT.md`.

Acceptance: `scripts/ci-build-service.sh <svc> <version>` produces a manifest with both
new fields for all existing services; numbers are reproducible within ±15 %.

### 0.2 Runtime profile contract (`overlay/runtime.env`)

Add a per-service `services/<svc>/overlay/runtime.env` holding **low-footprint local-dev
defaults** (env vars baked into the image as `ENV` defaults via `Dockerfile.slim` /
`scripts/build-image-from-artifact.sh`). The CLI can override any of them at `docker run`
time, so baking defaults is safe and keeps prod images unaffected (these are local-dev
images). Every service section below specifies its `runtime.env` content.

Acceptance: `docker inspect` on each slim image shows the documented ENV defaults; smoke
tests still pass with them applied.

### 0.3 Shared runtime recipes by language family

Apply uniformly wherever a section below references them:

- **BEAM family** (realtime, analytics, pooler) — biggest idle-CPU lever in the whole
  stack. Default ERL flags for local dev:
  `+S 1:1 +SDio 1 +sbwt none +sbwtdcpu none +sbwtdio none`
  (1 scheduler, no scheduler busy-waiting — idle BEAM VMs with default busy-wait burn
  measurable CPU on every one of the 25 stacks). Deliver via `ELIXIR_ERL_OPTIONS` /
  `ERL_FLAGS` in `runtime.env` or the release `vm.args` in `overlay/`.
- **Node family** (storage, pgmeta, studio):
  `NODE_OPTIONS=--max-old-space-size=<cap> --max-semi-space-size=2`, plus
  `NODE_ENV=production`. Caps per service below.
- **Go family** (auth, imgproxy, mailpit): `GOMEMLIMIT=<cap>`, `GOGC=50`,
  `GOMAXPROCS=2` (a Go runtime on a 10-core host otherwise spins up 10 Ps per process;
  ×25 stacks this is real scheduler churn).
- **DB connection pools**: every service that opens a postgres pool holds *server-side
  backends* (~5–15 MiB each inside postgres). Shrinking client pools is therefore a
  postgres-RAM lever too. Each section lists its pool knob.

---

## 1. New services to onboard

Scope rule: this pass focuses on **Supabase-owned services** (postgres, postgrest, auth,
realtime, storage, edge-runtime, analytics/logflare, studio, pgmeta, pooler). Third-party
images the stack merely consumes (kong, imgproxy, vector, mailpit) are deferred to §1.2 —
low priority for now.

### 1.1 `postgres` — NEW, the single biggest item on every axis (P0)

Upstream `supabase/postgres:17.6.1.141` is ~1.3 GB — 3× the entire current slim set —
and postgres is also the largest per-stack RSS consumer.

Create `services/postgres/` following the existing recipe layout
(`recipe.env`, `Dockerfile.slim`, `overlay/`, `smoke.sh`, `REPORT.md`).

**Disk**
- Backend: prune the published Nix-based image in a `Dockerfile.artifact`
  (`FROM supabase/postgres:<version>`), walking the Nix reference graph from the
  runtime roots.
- **Decision (2026-07): keep EVERY extension the upstream image ships.** This is
  the `supabase/postgres` flavour — users must be able to `CREATE EXTENSION`
  anything Supabase supports locally (PostGIS, pgroonga, wrappers, pgrouting,
  rum, pgmq, ...). The prune removes only what never executes at runtime:
  Nix tooling, `.drv` build derivations, unreferenced store paths (the image
  ships ~6,700 store paths; the runtime closure is a few hundred), and the
  `switch_*_version` scripts whose alternate extension versions would double
  parts of the closure (default versions all stay).
- Target: ~300 MiB compressed (from ~350 MiB upstream) — the disk win is
  modest by design; the RAM/CPU profile is where this service pays off at 25×.

**RAM** — `overlay/postgresql.local.conf` appended via include, values as ENV-overridable
defaults where the entrypoint templates them:
```
shared_buffers = 32MB          # local dev; page cache covers reads
max_connections = 30           # pools below are shrunk to match
work_mem = 2MB
maintenance_work_mem = 16MB
effective_cache_size = 128MB
wal_level = logical            # required by realtime — do not lower
max_wal_size = 128MB
jit = off
huge_pages = off
```
**CPU**
- `autovacuum_naptime = 60s`, `bgwriter_delay = 2000ms`, `wal_writer_delay = 2000ms` —
  idle-tick reduction that multiplies ×25.

**Acceptance**: smoke = initdb + start + `CREATE EXTENSION` for every kept extension +
auth/postgrest migrations apply. Measured idle RSS ≤ 120 MiB, idle CPU < 1 %.

### 1.2 Deferred: third-party images — kong (gateway), imgproxy, vector, mailpit (LOW)

These are not Supabase-owned; keep upstream images as-is for now and revisit after the
owned services land. Recorded here so the analysis isn't lost:

- **gateway (Kong → nginx)**: Kong (OpenResty + Lua) costs 60–120 MiB RSS + Lua worker
  CPU per stack. The CLI's sandbox mode already replaces it with a generated
  `nginx.conf` as a host binary — that track supersedes a slim Kong image, so no image
  work here. If a container gateway is later needed: `services/gateway/` with nginx
  (≤ 10 MiB compressed, ≤ 15 MiB RSS, `worker_processes 1`), porting the CLI's Kong
  declarative routing contract (`/auth/v1`, `/rest/v1`, `/realtime/v1`, `/storage/v1`,
  `/functions/v1`, apikey check, CORS, websocket upgrade), and documenting any Kong
  plugin behavior nginx does not reproduce.
- **imgproxy** (`darthsim/imgproxy:v3.8.0`): minimal-libvips source build (jpeg/png/webp/
  gif only) on distroless cc, ≤ 40 MiB compressed; `runtime.env` with
  `IMGPROXY_WORKERS=1`, `GOMEMLIMIT=64MiB`, `GOMAXPROCS=2`.
- **vector** (0.53.0-alpine): static-binary repack ≤ 30 MiB — only worth it if analytics
  stays default-on.
- **mailpit** (v1.30.2): already small; at most `GOMEMLIMIT=48MiB`, `GOMAXPROCS=2` via
  run-time env from the CLI. Skip disk work.

---

## 2. Existing services — next optimization pass

Ordered by expected impact on the RAM/CPU axes, then disk.

### 2.1 `realtime` (BEAM) — P0 for CPU/RAM

Current: 28.5 MiB compressed, `cc-debian13`, phase-2 adopted.

- **CPU/RAM**: apply the BEAM recipe (§0.3) via `overlay/rel/vm.args.eex` or
  `ELIXIR_ERL_OPTIONS` in `runtime.env` (the overlay `run.sh` already exists —
  extend it). Add `runtime.env`: `DB_POOL_SIZE=2` (server-side backends!),
  `RLIMIT_NOFILE=10000` (already plumbed in `overlay/run.sh`).
  Expected: idle RSS from ~150 MiB → ≤ 90 MiB; idle CPU from several % → < 0.5 %.
- **Disk** (small, from `services/realtime/REPORT.md` follow-ups): trim unused BEAM
  release tools from the release directory; re-test `base-debian13` instead of
  `cc-debian13` (needs the libstdc++ audit that blocked it last time).

**Acceptance**: existing smoke passes; measured `idle_cpu_pct` < 0.5 and RSS delta
recorded in REPORT.md.

### 2.2 `analytics` / logflare (BEAM) — P0 for RAM

**Decision (2026-07): analytics is DISABLED by default in the minimal local
stack** (measured ~507 MiB idle RSS even with the runtime profile — untenable
per-stack at 25×). The slim image below exists for when it is enabled.

Current: 89.4 MiB compressed — the largest slim image after studio, and one of the
largest RSS consumers (BEAM + BigQuery client surface).

- **CPU/RAM**: BEAM recipe (§0.3). `runtime.env`: postgres backend only
  (`LOGFLARE_SINGLE_TENANT=true` is already how the CLI runs it), pool size 2.
  Expected idle RSS ≤ 150 MiB (from ~250 MiB).
- **Disk** (from `services/analytics/REPORT.md` follow-ups): remove BEAM tools not needed
  at runtime (compilers, `dialyzer`, `typer`); prune the BigQuery/Google API client
  modules if smoke coverage can be broadened to prove the postgres backend never loads
  them. Target ≤ 70 MiB.

**Acceptance**: smoke passes in single-tenant/postgres mode; both axes recorded.

### 2.3 `studio` (Node/Next.js) — P1

**Decision (2026-07): studio is DISABLED by default in the minimal local
stack** (~200 MiB idle RSS per stack; start it on demand or share one
instance). The slim image below exists for when it is enabled.

Current: 128.4 MiB compressed — largest slim image; heaviest Node process at runtime.

- **RAM**: `runtime.env`: `NODE_OPTIONS=--max-old-space-size=192 --max-semi-space-size=2`,
  `NEXT_TELEMETRY_DISABLED=1`. Expected idle RSS ≤ 220 MiB (from ~300 MiB).
- **Disk**: revisit the rejected phase-2 local-dev profile (10.9 MiB Sharp removal) —
  re-evaluate with a smoke test that exercises the image-optimization route so the
  decision is evidence-based this time; prune non-English Next.js locale/data files if
  present. Target ≤ 115 MiB.
- Note for the CLI (out of scope here, record in REPORT): studio is the top candidate
  for run-one-shared-instance or lazy start across parallel stacks.

### 2.4 `storage` (Node) — P1

Current: 55.5 MiB compressed, rolldown-bundled.

- **RAM**: `runtime.env`: `NODE_OPTIONS=--max-old-space-size=128 --max-semi-space-size=2`,
  `DATABASE_POOL_MAX=2` (verify exact knob name in storage config), disable the image
  transformation path by default (`ENABLE_IMAGE_TRANSFORMATION=false` locally unless
  imgproxy is enabled). Expected idle RSS ≤ 90 MiB.
- **Disk** (from `services/storage/REPORT.md` follow-ups): audit AWS/Smithy, Kubernetes,
  and vector/Iceberg dependency surfaces in the rolldown bundle for a local-dev profile
  (S3-file-backend only). Requires broadening smoke beyond `/status` first (upload,
  download, signed URL). Target ≤ 45 MiB.

### 2.5 `edge-runtime` (Deno/Rust) — P1

Current: 60.8 MiB compressed; ONNX Runtime + OpenBLAS ≈ 42 MiB of the artifact and are
mapped into RSS even when unused.

- **Disk+RAM in one move** (from `services/edge-runtime/REPORT.md` follow-ups): build the
  no-ONNX/no-AI local-dev profile via the Nix package's feature switches
  (`services/edge-runtime/nix/edge-runtime.nix`). Ship it as the default local tag;
  keep the full build as `-ai` variant. Target ≤ 30 MiB compressed, idle RSS ≤ 60 MiB.
- **CPU**: verify the per-worker event loop is quiescent when no functions are deployed
  (measure; if the main worker polls, tune `EDGE_RUNTIME_*` worker pool settings to 1).

### 2.6 `postgrest` (Haskell) — P2

Current: 21.2 MiB compressed, scratch. Disk is near-done.

- **RAM (the real lever is server-side)**: `runtime.env`: `PGRST_DB_POOL=2`
  (default 10 → holds 10 postgres backends per stack ≈ 50–150 MiB inside postgres),
  `PGRST_ADMIN_SERVER_PORT` unset (off), `PGRST_DB_CHANNEL_ENABLED=true` (keep; cheap).
- **Disk**: switch to a true static arm64 binary when upstream publishes one (tracked in
  `services/postgrest/REPORT.md`); the Nix static experiment
  (`services/postgrest/nix/static-v14_10-arm64.nix`) is the fallback path. Target ≤ 8 MiB.

### 2.7 `auth` / gotrue (Go) — P2

Current: 10.2 MiB compressed, scratch, static. Disk is done — do not chase further binary
shrinking (UPX explicitly rejected: it defeats page-cache sharing and increases RSS).

- **RAM/CPU**: `runtime.env`: `GOMEMLIMIT=64MiB`, `GOGC=50`, `GOMAXPROCS=2`,
  `GOTRUE_DB_MAX_POOL_SIZE=2` (verify knob name). Expected idle RSS ≤ 25 MiB.

### 2.8 `pgmeta` (Node) — P2

Current: 52.1 MiB compressed; phase-2 bundling rejected (2.4 MiB below threshold) — keep
that decision, no further disk work.

- **RAM**: `runtime.env`: `NODE_OPTIONS=--max-old-space-size=96 --max-semi-space-size=2`,
  pool size 1 (pgmeta opens connections per request; verify `PG_META_DB_*` pooling).
  Expected idle RSS ≤ 70 MiB.

### 2.9 `pooler` / supavisor (BEAM) — P2 (opt-in service, lowest priority)

Current: 24.3 MiB compressed. Disabled by default in the CLI.

- **CPU/RAM**: BEAM recipe (§0.3) in `overlay/` (extends existing `limits.sh`).
- **Disk** (from `services/pooler/REPORT.md` follow-ups): move off the Bullseye/OpenSSL 1.1
  carry-over (build against OpenSSL 3 or the upstream Nix flake backend); trim BEAM
  release extras.

---

## 3. Priority summary for the implementing agent

| Order | Item | Axis | Expected win (×25 stacks) |
|---|---|---|---|
| 1 | §0.1 RSS/CPU measurement in pipeline | — | Makes every other row verifiable |
| 2 | §1.1 postgres slim + local conf | disk+RAM+CPU | ~1 GB disk once; ~1–2 GB RAM; idle-tick CPU |
| 3 | §2.1/§2.2 BEAM flags (realtime, analytics) + pruning | CPU+RAM | ~2–4 GB RAM; largest idle-CPU fix |
| 4 | §0.2 runtime.env for all existing services | RAM | ~1–2 GB aggregate via heap caps + pools |
| 5 | §2.5 edge-runtime no-ONNX profile | disk+RAM | ~30 MiB disk; ~1 GB RAM |
| 6 | §2.3/§2.4 studio & storage profiles | RAM+disk | ~1–2 GB RAM |
| 7 | §2.6–2.9 postgrest, auth, pgmeta, pooler | all, smaller | owned long tail |
| 8 | §1.2 third-party images (kong, imgproxy, vector, mailpit) | all | deferred — not Supabase-owned |

## 4. Verification (applies to every item)

1. `scripts/ci-build-service.sh <service> <version>` — build, smoke, measure must pass.
2. Manifest deltas: record before/after `image_compressed_bytes`, `runtime_rss_bytes`,
   `idle_cpu_pct` in the service `REPORT.md` and refresh `SLIM_IMAGES_REPORT.md`.
3. Runtime defaults must be overridable: re-run smoke with one `runtime.env` var
   overridden via `docker run -e` to prove the CLI can tune them.
4. End-to-end (once postgres lands): boot the full slim set with the CLI
   (`INTERNAL_IMAGE_REGISTRY` override pointing at local builds, upstream images for the
   deferred third-party services), run
   auth signup + REST query + realtime subscribe; then launch 5 concurrent project-id
   namespaced stacks and record aggregate RSS — extrapolate to 25 before claiming the
   32 GB target.

## 5. Explicit non-goals of this pass

- CLI-side orchestration work (lazy service start, shared singleton studio/analytics,
  port auto-allocation, memory limits via `container.HostConfig.Resources`) — tracked in
  the CLI repo; this repo only ships images whose defaults make those limits safe.
- Host-native darwin binaries — same artifacts, separate packaging track
  (see `NIX_PORTABLE_ARTIFACT_PLAYBOOK.md` and `CI_MATRIX.md`).
- Prod image changes — everything here targets the local-development profile only.
