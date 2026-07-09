# Portability & Self-Containedness — Next Session Handoff

> **For the next session:** this is a multi-PR roadmap handoff, not a single implementation plan. For each workstream, run superpowers:brainstorming only where marked OPEN QUESTIONS, then superpowers:writing-plans, then execute (subagent-driven-development worked well last time: fresh implementer per task + task review + final whole-branch review — it caught real bugs every single round). One PR per workstream; sequence below.

## Where things stand (post PR #14, merged 2026-07-09)

PR #14 ("Host portability: measured OS floors, audit gates, and floor-container execution proof") landed the enforcement layer. Current contract, all CI-verified green:

- **Floors (measured, gated):** Linux glibc **2.39** (Ubuntu 24.04+/Debian 13+/Fedora 40+); macOS **14.0**. Static (no floor): auth, postgrest linux-amd64.
- **At the floor:** `dylib/libsystemd.so.0` (realtime/pooler/analytics — the BEAM trio), `wrappers.so`/`wrappers-0.6.2.so` pgrx extension (postgres linux); `bin/.pg_ctl-wrapped` and upstream `bin/postgrest` at minos 14.0 (darwin); storage's `fs-xattr` node addon at 13.5.
- **Tooling you'll build on:**
  - `scripts/os-floor.sh --linux|--darwin ROOTFS` → one JSON object on stdout: `{"kind","floor","offender","scanned","bundled_glibc"}`; exit 0 always except usage/IO errors; never crashes on malformed ELFs.
  - `scripts/audit-portable-artifact.sh` — gates: standard ELF interpreter only (`/lib/ld-linux-aarch64.so.1`, `/lib64/ld-linux-x86-64.so.2`), glibc floor ≤ `${GLIBC_FLOOR_MAX:-${SLIM_GLIBC_FLOOR_MAX:-2.39}}`, macOS ≤ `${MACOS_FLOOR_MAX:-${SLIM_MACOS_FLOOR_MAX:-14.0}}`. `bundled_glibc: true` → static glibc gate skipped (execution proof is the guard, and ci-build-service.sh FAILS if such an artifact has no `FLOOR_CHECK_CMD`).
  - `scripts/floor-check-linux.sh SERVICE ROOTFS` — runs the recipe's `FLOOR_CHECK_CMD` in `ubuntu:24.04` (glibc 2.39 exactly), `--network none --hostname slim-floor-check --add-host slim-floor-check=127.0.0.1` (BEAM release scripts call `hostname -f`), rootfs ro-mounted at `/rootfs`, env `ROOTFS=/rootfs HOME=/tmp RELEASE_TMP=/tmp`. Recipes without the var are skipped WITH a log line.
  - Manifests carry `target`, `libc` (`"glibc"`|null), `os_floor`.
  - `TARGET_LIBC=musl` → `linux-<arch>-musl` naming reserved in `scripts/lib.sh:artifact_platform_dir`; ci-build-service.sh fails fast on non-glibc until implemented.
  - `SPLIT_BUNDLED_GLIBC="true"` (postgrest recipe) → `scripts/build-artifact-from-image.sh` moves the glibc family to `lib/<triplet>/`, sets `$ORIGIN/../usr/lib/<triplet>` rpath on the binary AND `$ORIGIN` on each bundled `.so` (DT_RUNPATH is NOT transitive — libpq must find the krb5 stack itself). Requires an apt-capable SOURCE_IMAGE (installs patchelf).
- **Plan history:** `docs/superpowers/plans/2026-07-08-host-portability-floors.md` (its 2.38/13.0/fedora:39 values were pre-measurement; superseded, recorded in HOST_NATIVE_PLAN.md).
- **Known environmental facts:** the `refresh results tables` CI job always fails — org setting "Allow GitHub Actions to create and approve pull requests" is disabled (user-level fix; refresh locally via `scripts/update-results-tables.sh --merge` meanwhile). arm64 CI audit logs show non-fatal `ldd` "Bus error" noise (pre-existing). macOS CI runs repo scripts under bash 3.2 — `/bin/bash -n` everything; no apostrophes in comments inside `$()`, no case-parens inside `$()`.

## Authoritative user decisions (do not re-litigate)

1. **Node runtime (REVERSES the 2026-07-07 "Option A shared runtime" decision in HOST_NATIVE_PLAN.md):** first TEST storage and pg-meta against the **latest Node LTS**; if both pass, **bundle Node into each archive** so storage and pg-meta are truly self-contained. Disk cost is explicitly accepted — self-containedness wins over size. Update the decision record in HOST_NATIVE_PLAN.md when implementing.
2. Archives must run as-extracted; **no CLI-side relocation logic** ever.
3. `linux-<arch>` = glibc default (no `-gnu` suffix); musl variants are `linux-<arch>-musl`.
4. Studio stays docker-only (standing non-goal).
5. Lowering Linux below 2.38 (old-glibc toolchain surgery for Ubuntu 22.04/RHEL 9) is demand-gated — not on this roadmap.

---

## PR 1 — Bundle Node into the storage and pg-meta archives (self-containedness)

**Goal:** `storage-*.tar.zst` and `pgmeta-*.tar.zst` run with zero external runtime on all three targets.

Steps:
1. **Compatibility test first (cheap, decides everything):** identify the latest Node LTS (check nodesource/nodejs.org; verify the shared nixpkgs pin `scripts/nixpkgs-pin.sh` has that `nodejs_XX` attr — storage currently declares `node>=20` in `runtime_requires`; storage build also wanted `npm>=11.12.1` at build time). Run both services' existing artifact smokes (`scripts/smoke.sh storage --artifact ...`, same for pgmeta) with that Node on PATH/`SUPABASE_NODE`. If either fails on latest LTS, fall back to the newest LTS that passes and record why.
2. **Bundle:** in each service's `build-host.sh`, copy the pinned nixpkgs Node (same pin as everything else → floor stays within 2.39/14.0 gates; official nodejs.org builds would also pass floors but break the single-pin provenance story) into `<rootfs>/node/`. Update the wrapper resolution order to prefer the bundled runtime: `$SUPABASE_NODE` (explicit override) → **`<rootfs>/node/bin/node` (bundled, new default)** → PATH fallback. Wrapper lives via `WRAPPER_PATH`/`services/<svc>/wrapper.sh` (see build-artifact-from-source.sh host path).
3. **Gates:** the bundled node binary is now in scope for os-floor/audit automatically. Add `FLOOR_CHECK_CMD` to both recipes (now possible!): run the bundled node against the real bundle entry, e.g. `"$ROOTFS/node/bin/node" --version && "$ROOTFS/<wrapper>" --help`-equivalent — brainstorm the cheapest command that loads the app bundle + native addons (`fs-xattr` for storage, sentry profiler for pgmeta). Remove the "documented skip" comments. Drop `runtime_requires` from the manifests (or keep as informational `"bundled"` marker — small design choice).
4. **Docker derivation decision (OPEN QUESTION for brainstorm):** images currently use a distroless nodejs base (`ENTRYPOINT ["/nodejs/bin/node"]`). Native-first says derive from the rootfs — either (a) switch base to `base-debian13` and use the bundled `/node/bin/node` (one node provenance, slightly larger image), or (b) keep the distroless-node base and have Dockerfile.slim ignore the bundled `node/` dir (smaller image, two node provenances). User accepted archive-size cost, not necessarily image-size cost — ask, or default to (a) for consistency and measure both.
5. **Expect** ~+30 MiB compressed per archive per target. Refresh results tables; update HOST_NATIVE_PLAN.md Option A decision record and CI_MATRIX.md's "Node duo resolves the shared Node runtime" sentence, README.

Acceptance: both services' archives pass floor-check in ubuntu:24.04 with NOTHING preinstalled; darwin artifact smoke green on a runner with no Node on PATH (unset/hide PATH node in the smoke to prove it); CI matrix green.

## PR 2 — glibc runtime side-data (close the last host-file dependencies)

**Status: done.** Tasks 1/2/4 below were written before the evidence existed;
task 3's open point is resolved. Full record, evidence, and sweep results:
`docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md`.

Outcomes:
- No NSS bundling anywhere — NSS `files`/`dns` are compiled into libc at the
  2.39 floor; bundling host-glibc modules would add cross-glibc coupling.
  Floor-check gained an execution proof instead (below).
- tzdata bundled for the BEAM trio only (realtime, pooler, analytics), with a
  `TZDIR` guard appended to each release's `env.sh`; Node duo and postgres
  carry their own tz data and need nothing.
- No gconv bundling for host-glibc artifacts — their only iconv importer,
  `libstdc++.so.6`, reads host gconv. postgrest (the one bundled-glibc
  artifact) does import iconv itself; fixed by shipping its own source
  image's gconv modules via `OPTIONAL_INCLUDE_PATHS` — no wrapper, no
  `GCONV_PATH` (the sweep found this; the plan's original wrapper sketch
  didn't hold up).
- No locale bundling: stock glibc ignores `LOCALE_ARCHIVE` (a Nix-glibc
  patch) and `LOCPATH` can't read archive files; `C.UTF-8` is built in.
- No audit WARN for side-data (execution proof over static heuristics, per
  PR #14 philosophy).
- `FLOOR_CHECK_CMD` extended on all five affected recipes — BEAM trio: NSS
  resolution (`:inet.gethostbyname`) + a >=3h TZ delta; Node duo:
  `dns.lookup` — proven green on linux-arm64, including a non-vacuous tamper
  test on pooler.

## PR 3 — BEAM floor 2.39 → 2.38 (drop libsystemd) + upstream nudge for postgres

1. `dylib/libsystemd.so.0` enters via the OTP build in the shared pin (almost certainly nixpkgs erlang's `systemdSupport`). Rebuild `erlang_27` with `systemdSupport = false` (override in each BEAM service's `services/<svc>/nix/default.nix`, or a shared overlay) — costs an OTP compile in CI (~20-40 min, cached by cache-nix-action thereafter).
2. Verify with `scripts/os-floor.sh --linux` that the trio lands ≤ 2.38 (ERTS `beam.smp` itself measured exactly `GLIBC_2.38` on the pin — that's the next floor down; going lower is the demand-gated toolchain project).
3. Set `GLIBC_FLOOR_MAX="2.38"` in the three recipes so the gain is locked in per-service (repo default stays 2.39 while postgres needs it).
4. postgres: file an upstream issue on supabase/postgres — `wrappers.so` (pgrx) links GLIBC_2.39; ask for a lower link floor in their flake toolchain. Reference: our manifests record per-service floors, so any upstream improvement lands automatically at the next version bump.
5. Docs: floor policy stays 2.39 repo-wide (postgres), but CI_MATRIX gains a per-service floor table (generate from manifests).

## PR 4 — First musl target: auth (`linux-<arch>-musl`)

Cheap end-to-end proof of the reserved plumbing. auth is static Go (`CGO_ENABLED=0`) — the same binary serves both libcs.

1. Remove/condition the `TARGET_LIBC != glibc` fail-fast in ci-build-service.sh for services that declare musl support (recipe flag, e.g. `SUPPORTS_MUSL="true"`; everything else keeps failing fast).
2. `artifact_platform_dir` already emits `linux-<arch>-musl`; wire the matrix (workflow `targets` input) and manifest `libc: "musl"`.
3. Floor-check image for musl targets: `alpine:3.20`+ (env `SLIM_FLOOR_IMAGE` already exists; make floor-check pick the default by target libc). os-floor's glibc scan is meaningless for musl — record `os_floor: {"kind":"musl", ...}` or floor null; brainstorm the minimal honest contract.
4. Docs: CI_MATRIX naming section already reserves this — flip "reserved, no builds" to auth-only.

## PR 5 — darwin store-denied execution proof + deployment-target pins

1. The disksup incident (nix store bash path compiled INSIDE `disksup.beam`'s literal chunk — invisible to strings/otool/ldd) and the libiconv signature bug both only fail OFF the build machine. Add a darwin analog of floor-check: run each service's darwin artifact smoke under `sandbox-exec` with a profile denying `/nix/store` reads (build-machine leak simulation). macOS `sandbox-exec` is deprecated-but-functional; brainstorm alternatives (a throwaway user account, or `DYLD_*` tricks won't cover exec'd children — sandbox-exec is the credible one).
2. Pin `MACOSX_DEPLOYMENT_TARGET` explicitly in repo-owned nix builds (nixpkgs `darwinMinVersionHook`) so the 14.0 floor is chosen, not inherited from SDK drift; upstream postgrest binary stays 14.0 regardless.

## PR 6 — NixOS flake outputs

Expose the repo-owned service packages (`services/*/nix/default.nix`, postgres overlay) as a top-level `flake.nix` with per-system outputs. No archives for NixOS ever (no standard loader path) — this is the supported answer. Small PR; mostly plumbing + README section. Mind: service nix files are currently applied as overlays onto submodule exports (NIX_PACKAGE_OVERLAY mechanics in build-artifact-from-nix.sh) — the flake must reproduce that composition; brainstorm whether to require submodules initialized or fetch pinned sources itself.

## Suggested sequencing

PR 1 (Node bundling — biggest user-visible self-containedness win, and the user's explicit priority) → PR 2 (side-data) → PR 3 (BEAM 2.38) in one arc; PR 4/5/6 are independent and can interleave. After each PR: dispatch `service-artifacts.yml` (+ `edge-runtime-artifacts.yml` if scripts/ changed) with `force=true` for touched services; refresh tables locally.

## Verification recipes (copy-paste)

```bash
# floor of any rootfs
scripts/os-floor.sh --linux  artifacts/<svc>/<ver>/linux-arm64/rootfs
scripts/os-floor.sh --darwin artifacts/<svc>/<ver>/darwin-arm64/rootfs
# execution proof (Docker Desktop on this Mac runs linux/arm64 natively)
scripts/floor-check-linux.sh <svc> artifacts/<svc>/<ver>/linux-arm64/rootfs
# full linux cell locally (build + audit + floors + floor-check + image + smoke)
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh <svc> <ver>
# audit inside a clean container (macOS host lacks readelf/ldd)
docker run --rm -v "$PWD":/repo -w /repo ubuntu:24.04 bash -c \
  'apt-get -qq update && apt-get -qq install -y binutils file libc-bin python3 >/dev/null && bash scripts/audit-portable-artifact.sh --linux artifacts/<svc>/<ver>/linux-arm64/rootfs'
# CI dispatch
gh workflow run service-artifacts.yml --ref <branch> -f services="storage pgmeta" -f force=true
```

## Gotcha index (hard-won, do not rediscover)

- bash 3.2 on macOS CI: `bash -n` every script; no `${var,,}`, no assoc arrays, no apostrophes in comments inside `$()`, no case-parens inside `$()`.
- `readelf -l` INTERP line is `[Requesting program interpreter: /path]` — strip the `interpreter: ` prefix, not just brackets.
- DT_RUNPATH is not transitive: bundled `.so`s need their own `$ORIGIN` rpath.
- `hostname -f` fails under docker `--network none` without `--hostname`+`--add-host`; BEAM release scripts call it.
- BEAM floor checks: `bin/<release> eval` evaluates runtime config → needs the smoke's dummy env vars; `:crypto.hash` forces the NIF (openssl dylib) load without any DB connection. `bin/<release> version` does NOT boot the VM (useless as a loader proof).
- Mix-release env lists live in each `services/<svc>/smoke.sh` — mirror them exactly.
- glibc dlopens NSS modules invisibly to ldd; nixpkgs OTP's disksup embeds a store bash path inside beam bytecode (fix: `-os_mon start_disksup false` in vm.args — already in the playbook).
- GNU strip corrupts patchelf-ed binaries: always strip BEFORE patchelf.
- stale local `artifacts/` trees may predate native-first — check `manifest.json`'s `build_backend`/`portable` before trusting them as fixtures.
- `git submodule update --depth 1` misses recipe tags → `resolve_source_ref` shallow-fetches; keep it.
- Killing a docker buildx client does not cancel the server-side build (OrbStack recovery: `orb restart docker`).
- glibc >= 2.34 compiles nss_files/nss_dns into libc: bundling NSS modules
  for host-glibc artifacts is wrong (cross-glibc `dlopen`), not just
  unnecessary.
- Stock glibc ignores `LOCALE_ARCHIVE` (a Nix-glibc patch) and `LOCPATH`
  cannot read archive files — a bundled locale archive is inert for
  host-glibc artifacts.
- Erlang never calls glibc iconv (pure-ERTS unicode): an iconv floor-check
  in a BEAM eval is unimplementable without a NIF.
- On a darwin host, `ci-build-service.sh` skips its in-build audit/floor-check
  steps for linux targets (host-OS gate, pre-existing) — run
  `scripts/floor-check-linux.sh` directly for local linux proofs.
