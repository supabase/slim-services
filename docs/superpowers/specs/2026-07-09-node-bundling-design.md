# Bundle Node into the storage and pg-meta archives — design

Date: 2026-07-09. Implements PR 1 of `docs/superpowers/plans/2026-07-09-portability-next-handoff.md`.
Authoritative inputs: the handoff's "Authoritative user decisions" (bundle Node, disk cost accepted,
no CLI-side relocation, reverses the 2026-07-07 Option A shared-runtime decision).

## Goal

`storage-*.tar.zst` and `pgmeta-*.tar.zst` run as-extracted with **zero external runtime** on all
three targets (linux-amd64, linux-arm64, darwin-arm64). The wrapper prefers a bundled
`<rootfs>/node/bin/node`; the archives gain a floor-check execution proof like every other
bundled-runtime service.

## Current state (what changes)

- Both services build via `ARTIFACT_SOURCE_BUILD="host"` → `services/<svc>/build-host.sh`, which
  resolves node from the shared nixpkgs pin **for the build only** (storage: `nodejs_24`,
  pgmeta: `nodejs_20`) and ships a JS bundle with no runtime.
- Wrapper (`rootfs/bin/<svc>`, generated inside each `build-host.sh`) resolves node:
  `$SUPABASE_NODE` → `../../node/bin/node` (CLI shared-runtime location) → PATH.
- `recipe.env` sets `RUNTIME_REQUIRES="node>=20"` and documents the FLOOR_CHECK_CMD skip
  ("no bundled runtime").
- Docker images use distroless nodejs bases — **already drifted**: storage
  `gcr.io/distroless/nodejs24-debian13:nonroot`, pgmeta `gcr.io/distroless/nodejs20-debian13:nonroot`,
  `ENTRYPOINT ["/nodejs/bin/node"]`; `Dockerfile.slim` copies only `app/`.
- Artifact smokes export `SUPABASE_NODE` from the pin (shared-runtime shim).

## Decisions

### D1 — Node version: latest LTS = Node 24, single pin, both services

Node 24 is the active LTS (Node 25 is non-LTS current; 26 goes LTS 2026-10). Storage already
builds and smokes on the pin's `nodejs_24`. **Compat test first:** run the pg-meta build + artifact
smoke on `nodejs_24`; if it fails, fall back per handoff (newest passing LTS) and record why.
On pass, pgmeta's `build-host.sh` moves to `nodejs_24` — the build node MUST match the bundled
node major because `npm ci` compiles/fetches native addons for the build node's ABI
(NODE_MODULE_VERSION).

### D2 — Portable node bundle: repo-owned shared nix derivation, pooler playbook

A single shared derivation (`nix/portable-node/default.nix`, imported by both `build-host.sh`
scripts via the shared pin) stages `nodejs_24` into a self-contained layout and applies the
proven portability playbook (reference: `services/pooler/nix/default.nix` postFixup,
`NIX_PORTABLE_ARTIFACT_PLAYBOOK.md`):

- **linux:** collect the non-glibc dylib closure next to the binary, strip **then** patchelf
  (GNU strip corrupts patchelf-ed binaries), `--set-interpreter` to the standard loader
  (`/lib/ld-linux-aarch64.so.1` / `/lib64/ld-linux-x86-64.so.2`), `$ORIGIN`-relative rpaths on the
  binary AND every bundled `.so` (DT_RUNPATH is not transitive). glibc family excluded
  (host-provided; list = `portable_host_libs_json` in `scripts/lib.sh`). `bundled_glibc` stays
  false — the 2.39 static gate applies to the node binary and its closure.
- **darwin:** dylib closure collected, `/nix/store` references rewritten to `@rpath` via
  `install_name_tool`, nix-sandbox signature repair + ad-hoc re-sign after patching
  (libiconv-signature-bug playbook).

`build-host.sh` copies the derivation output to `<rootfs>/node/` (layout: `node/bin/node`,
`node/dylib/…` per playbook). Expected cost ~+30 MiB compressed per archive per target — accepted.

**Risk:** if the pin's node references glibc symbols > 2.39, the audit gate fails. The BEAM trio
from the same pin measures ≤ 2.39, so this is unlikely; the gate catches it deterministically.
Contingency (only if it fires): discuss before switching provenance — official nodejs.org builds
would pass floors but break the single-pin story.

### D3 — Wrapper resolution order

`$SUPABASE_NODE` (explicit override) → **`$SCRIPT_DIR/../node/bin/node` (bundled, new default)** →
`node` on PATH (last-resort). The old `../../node/bin/node` CLI shared-runtime probe is removed —
that mechanism is retired by this PR. No relocation logic (settled decision #2).

### D4 — FLOOR_CHECK_CMD (both recipes; skip comments removed)

Cheapest honest proof, no DB/network, runs under `floor-check-linux.sh`'s `--network none`
container with `ROOTFS` env:

1. `"$ROOTFS/node/bin/node" --version` — proves interpreter + node's full dylib closure loads at
   glibc 2.39 exactly.
2. `require()` every bundled `*.node` native addon (found under `$ROOTFS/app/node_modules`):
   `fs-xattr` for storage, the sentry CPU profiler for pgmeta. Native addons self-register on
   `require` of the `.node` file — loads the ELF without app configuration. (If a specific addon
   can't standalone-load, fall back to requiring its package entry; verify locally during
   implementation.)

### D5 — `runtime_requires`: dropped

Removed from both recipes → manifest field becomes `null` like non-node services. Its meaning is
"external runtime required"; with node bundled there is none. The bundled node version is visible
in the floor-check log; no new manifest field.

### D6 — Docker images derive from the bundled node (option a)

Both `Dockerfile.slim` switch to `gcr.io/distroless/base-debian13:nonroot` (glibc, no node), add
`COPY ${ARTIFACT_ROOT}/node/ /node/`, `ENTRYPOINT ["/node/bin/node"]` (recipe `ENTRYPOINT_JSON`
updated; `CMD_JSON` unchanged). Rationale: one node provenance; the image smoke then exercises the
exact runtime the archive ships; kills the existing node-24-vs-node-20 base drift. Both variants'
image sizes are measured once and recorded in the PR description (handoff asks for the
measurement; user accepted archive-size cost, image delta expected ≈ neutral since the distroless
node base is replaced by the bundle).

### D7 — Smokes prove self-containedness

Artifact smokes stop exporting `SUPABASE_NODE` (the shared-runtime shim): the wrapper must find
the bundled node on its own. The darwin artifact smoke additionally runs with node hidden from
PATH (sanitized PATH) to prove the no-external-runtime claim, per handoff acceptance.

## Out of scope

NSS/gconv/tzdata side-data (PR 2), musl (PR 4), deployment-target pins (PR 5), studio (docker-only
forever), CLI changes (separate repo — the retired shared-runtime download becomes dead code there,
not here).

## Docs & records to update

- `HOST_NATIVE_PLAN.md:181-192` — append a dated reversal record under the Option A decision
  (2026-07-09: bundle node per archive; self-containedness wins over size; shared-runtime
  mechanism retired).
- `CI_MATRIX.md:87` and `README.md:96` — replace the "Node duo resolves the shared Node runtime"
  sentences with the bundled-runtime contract.
- Results tables refreshed locally via `scripts/update-results-tables.sh --merge` after the CI
  validation run.
- The handoff doc itself (`docs/superpowers/plans/2026-07-09-portability-next-handoff.md`) is
  committed in this PR.

## Acceptance (from the handoff, verbatim intent)

- Both services' linux archives pass `floor-check-linux.sh` in `ubuntu:24.04` with nothing
  preinstalled.
- darwin artifact smokes green with no node on PATH and no `SUPABASE_NODE`.
- Full CI matrix green via forced `service-artifacts.yml` dispatch
  (`-f services="storage pgmeta" -f force=true`) before the PR opens.
- Manifests: `runtime_requires: null`; floors within 2.39 / 14.0 gates.
