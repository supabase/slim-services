# glibc Runtime Side-Data Implementation Plan (PR 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the last silent host-file dependencies: bundle tzdata + TZDIR for the BEAM trio, prove NSS resolution and TZ handling in floor checks, and settle gconv/locale by an iconv import scan instead of speculative bundling.

**Architecture:** Spec: `docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md` (read it first — it carries the evidence and decision rules). Three identical nix fixup additions (BEAM playbook), five recipe.env FLOOR_CHECK_CMD extensions, a verification sweep over locally built linux rootfs trees, docs, then CI dispatch + tables + PR.

**Tech Stack:** Nix (pinned nixpkgs `ac62194c…`), bash, Elixir release evals, Docker (linux-arm64 runs natively on this Mac).

## Global Constraints

- bash 3.2 compatibility for anything CI runs on macOS: `/bin/bash -n` every touched script; no `${var,,}`, no assoc arrays, no apostrophes in comments inside `$()`, no case-parens inside `$()`.
- FLOOR_CHECK_CMDs are **extended, never replaced** — every existing check stays.
- Launcher env lives in the artifact (release `env.sh`), never in CLI-side logic.
- No NSS, gconv, or locale bundling anywhere (spec decision; evidence in spec).
- `floor-check-linux.sh` invocation is unchanged: `--network none --hostname slim-floor-check --add-host slim-floor-check=127.0.0.1`, rootfs ro at `/rootfs`, `bash -c "set -euo pipefail; $FLOOR_CHECK_CMD"`.
- Long builds: run in background and poll in-turn (sleep-loop + tail the log); do NOT end your turn to "wait". Do not name a zsh variable `status`.
- Strip before patchelf (existing code already does; don't reorder).
- Commit after each task.

---

### Task 1: Extend the five FLOOR_CHECK_CMDs (the failing tests)

**Files:**
- Modify: `services/pooler/recipe.env:22`
- Modify: `services/realtime/recipe.env:23`
- Modify: `services/analytics/recipe.env:22`
- Modify: `services/storage/recipe.env:16`
- Modify: `services/pgmeta/recipe.env:16`

**Interfaces:**
- Produces: FLOOR_CHECK_CMDs that Task 3/4 exercise via `scripts/floor-check-linux.sh`. The BEAM TZ assertion only passes once Task 2 lands (this is the failing test).

- [ ] **Step 1: Rewrite the three BEAM FLOOR_CHECK_CMDs**

For each BEAM service, insert this comment block immediately above the `FLOOR_CHECK_CMD=` line (identical in all three recipes):

```bash
# Side-data proofs (see docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md):
# - gethostbyname resolves the --add-host name under --network none via
#   getaddrinfo (inet_gethost port binary -> glibc NSS). At the 2.39 floor,
#   nss_files/nss_dns are compiled into libc, so this proves the whole path;
#   the DNS wire protocol lives in the same libc and needs no separate check.
# - The TZ delta (>= 3h; New York is never UTC) proves the bundled zoneinfo
#   wired by the release env.sh TZDIR; missing tzdata silently degrades to
#   UTC and fails the match.
```

Then modify each `FLOOR_CHECK_CMD`: add `TZ=America/New_York` to the `env` prefix (right after `env `), and replace the eval expression. The shared eval body (only the release binary differs):

```
IO.puts(byte_size(:crypto.hash(:sha256, \"floor\"))); {:ok, _} = :inet.gethostbyname(String.to_charlist(\"slim-floor-check\")); l = :calendar.datetime_to_gregorian_seconds(:calendar.local_time()); u = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()); true = abs(l - u) >= 10800; IO.puts(\"side-data ok\")
```

(`String.to_charlist` instead of the `~c` sigil: analytics may run an Elixir older than 1.15. Match failures raise, `eval` exits non-zero, `set -euo pipefail` fails the check.)

Full new pooler line (the other two follow the same pattern with their existing env lists kept verbatim):

```bash
FLOOR_CHECK_CMD='env TZ=America/New_York DATABASE_URL=ecto://postgres:floor@127.0.0.1:5432/floor SECRET_KEY_BASE=floorcheckfloorcheckfloorcheckfloorcheckfloorcheckfloorcheck1234 API_JWT_SECRET=floor-check-api-secret-at-least-32ch METRICS_JWT_SECRET=floor-check-metrics-secret-32chars PORT=4000 "$ROOTFS/bin/supavisor" eval "IO.puts(byte_size(:crypto.hash(:sha256, \"floor\"))); {:ok, _} = :inet.gethostbyname(String.to_charlist(\"slim-floor-check\")); l = :calendar.datetime_to_gregorian_seconds(:calendar.local_time()); u = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()); true = abs(l - u) >= 10800; IO.puts(\"side-data ok\")"'
```

realtime keeps its `DB_HOST=… APP_NAME=floor PORT=4000` env list and `"$ROOTFS/bin/realtime"`; analytics keeps its `DB_DATABASE=… PHX_SECRET_KEY_BASE=…` env list and `"$ROOTFS/bin/logflare"`.

- [ ] **Step 2: Extend the two node FLOOR_CHECK_CMDs**

Append a `dns.lookup` proof (libuv → getaddrinfo, same NSS path) to the existing command — identical for storage and pgmeta. Insert this comment above the line:

```bash
# dns.lookup goes through getaddrinfo (libuv threadpool) -> glibc NSS; it
# resolves the floor-check --add-host name under --network none. See
# docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md.
```

New value (existing checks verbatim, new tail after the final `done`):

```bash
FLOOR_CHECK_CMD='"$ROOTFS/node/bin/node" --version && addons=$(find "$ROOTFS/app/node_modules" -type f -name "*.node") && [ -n "$addons" ] && for a in $addons; do echo "loading $a"; "$ROOTFS/node/bin/node" -e "require(process.argv[1])" "$a"; done && "$ROOTFS/node/bin/node" -e "require(\"node:dns\").lookup(process.argv[1], (err, addr) => { if (err) { console.error(err); process.exit(1); } console.log(\"dns.lookup\", addr); })" slim-floor-check'
```

- [ ] **Step 3: Syntax-verify every command as floor-check will run it**

```bash
for s in pooler realtime analytics storage pgmeta; do
  ( set -a; source "services/$s/recipe.env" >/dev/null 2>&1 || true
    f="$(mktemp)"; printf 'set -euo pipefail; %s\n' "$FLOOR_CHECK_CMD" > "$f"
    /bin/bash -n "$f" && echo "$s: syntax OK"; rm -f "$f" )
done
```

Expected: five `syntax OK` lines. Also `/bin/bash -n` passes for nothing else (no scripts touched in this task).

- [ ] **Step 4: Commit**

```bash
git add services/pooler/recipe.env services/realtime/recipe.env services/analytics/recipe.env services/storage/recipe.env services/pgmeta/recipe.env
git commit -m "floor-check: prove NSS resolution and TZ side-data (BEAM trio + node duo)"
```

---

### Task 2: Bundle tzdata + TZDIR in the three BEAM nix packages

**Files:**
- Modify: `services/pooler/nix/default.nix` (Linux postFixup half, after `mkdir -p "$dylib_dir"` at ~line 149)
- Modify: `services/realtime/nix/default.nix` (same position in its Linux half, ~line 133+)
- Modify: `services/analytics/nix/default.nix` (same position, ~line 199+)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `<rootfs>/share/zoneinfo/**` and a `TZDIR` guard appended to every `releases/*/env.sh` (sourced by `bin/<release>` on every invocation, after `RELEASE_ROOT` is set). Task 3/4's TZ floor check depends on this.

- [ ] **Step 1: Insert the identical block into all three files**

Each file's Linux half starts with the comment `# Linux half of the portable playbook: bundle every non-glibc shared` and then sets `rootfs="$out"`, `dylib_dir="$rootfs/dylib"`, `mkdir -p "$dylib_dir"`. Insert immediately after that `mkdir -p "$dylib_dir"` line, byte-identical in all three files (this is nix-indented-string code: `''${` renders a literal `${`):

```nix
      # Runtime side-data: bundle zoneinfo and point TZDIR at it from the
      # release env.sh. Minimal hosts may lack /usr/share/zoneinfo and glibc
      # silently falls back to UTC. NSS/gconv/locale need NO bundling at the
      # glibc 2.39 floor (nss_files/nss_dns are compiled into libc >= 2.34,
      # gconv ships with the host libc, C.UTF-8 is built in >= 2.35) — see
      # docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md.
      mkdir -p "$rootfs/share"
      cp -RL ${pkgs.tzdata}/share/zoneinfo "$rootfs/share/zoneinfo"
      chmod -R u+w "$rootfs/share/zoneinfo"
      # posix/ duplicates the top-level zones; right/ is the TAI variant.
      rm -rf "$rootfs/share/zoneinfo/posix" "$rootfs/share/zoneinfo/right"
      for envsh in "$rootfs"/releases/*/env.sh; do
        [ -f "$envsh" ] || continue
        {
          printf '\n## Portable artifact: prefer bundled zoneinfo (see nix package)\n'
          printf 'if [ -z "''${TZDIR:-}" ] && [ -d "$RELEASE_ROOT/share/zoneinfo" ]; then\n'
          printf '  export TZDIR="$RELEASE_ROOT/share/zoneinfo"\nfi\n'
        } >> "$envsh"
      done
```

Notes for the implementer:
- Linux half ONLY (macOS always ships `/usr/share/zoneinfo`; the darwin block must not change).
- The `printf` format strings are single-quoted shell: `$RELEASE_ROOT` and (via `''${`) `${TZDIR:-}` land literally in env.sh; user-set `TZDIR` wins at runtime.
- `cp -RL` dereferences symlinks on purpose (no store-symlink leaks possible).
- Zoneinfo TZif files are data, not ELF — the closure/patchelf loops below the insertion point ignore them; no interaction.

- [ ] **Step 2: Parse-check all three nix files**

```bash
PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH" bash -c '
for f in services/pooler/nix/default.nix services/realtime/nix/default.nix services/analytics/nix/default.nix; do
  nix-instantiate --parse "$f" >/dev/null && echo "$f: parse OK"
done'
```

Expected: three `parse OK` lines. Then confirm the three inserted blocks are byte-identical:

```bash
for f in services/pooler/nix/default.nix services/realtime/nix/default.nix services/analytics/nix/default.nix; do
  sed -n '/Runtime side-data/,/^      done$/p' "$f" | md5
done
```

Expected: three identical hashes.

- [ ] **Step 3: Commit**

```bash
git add services/pooler/nix/default.nix services/realtime/nix/default.nix services/analytics/nix/default.nix
git commit -m "pooler,realtime,analytics: bundle zoneinfo + TZDIR in the release env (linux)"
```

---

### Task 3: Local linux proof for pooler (build + floor-check + negative tamper test)

**Files:**
- No source changes. Produces `artifacts/pooler/<ver>/linux-arm64/rootfs` locally.

**Interfaces:**
- Consumes: Task 1's pooler FLOOR_CHECK_CMD, Task 2's pooler nix change.
- Produces: a built pooler linux-arm64 rootfs for Task 5's iconv scan; proof the new checks pass and are non-vacuous.

- [ ] **Step 1: Build the linux-arm64 cell**

Read the usage header of `scripts/ci-build-service.sh` first. The pooler version is `2.9.10` (see `services/pooler/nix/default.nix` `version =` line — verify, don't assume). Run in background and poll:

```bash
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh pooler 2.9.10 > /tmp/pooler-linux-build.log 2>&1 &
build_pid=$!
# then poll IN-TURN until done (do not end your turn):
while kill -0 "$build_pid" 2>/dev/null; do sleep 60; tail -3 /tmp/pooler-linux-build.log; done
tail -30 /tmp/pooler-linux-build.log
```

Expected: build + audit + floors + floor-check + image + smoke all green. The floor-check log must contain `side-data ok` (new eval) alongside the existing `32` (sha256 byte size).

- [ ] **Step 2: Confirm the artifact contents**

```bash
rootfs="$(ls -d artifacts/pooler/*/linux-arm64/rootfs | head -1)"
ls "$rootfs/share/zoneinfo/America/New_York" && echo "zoneinfo bundled"
tail -6 "$rootfs"/releases/*/env.sh   # must show the TZDIR guard
test ! -e "$rootfs/share/zoneinfo/right" && test ! -e "$rootfs/share/zoneinfo/posix" && echo "variants pruned"
du -sh "$rootfs/share/zoneinfo"
```

Expected: all four checks pass; zoneinfo raw size well under 40 MB (report the number).

- [ ] **Step 3: Negative tamper test (prove the TZ check can fail)**

```bash
rootfs="$(ls -d artifacts/pooler/*/linux-arm64/rootfs | head -1)"
mv "$rootfs/share/zoneinfo" "$rootfs/share/zoneinfo.off"
scripts/floor-check-linux.sh pooler "$rootfs" && echo "UNEXPECTED PASS" || echo "fails as expected"
mv "$rootfs/share/zoneinfo.off" "$rootfs/share/zoneinfo"
scripts/floor-check-linux.sh pooler "$rootfs" && echo "passes again"
```

Expected: `fails as expected` (MatchError on `true = abs(l - u) >= 10800`), then `passes again`. If the tamper run PASSES, the check is vacuous — stop and report (most likely cause: env.sh not sourced or TZDIR guard missing).

- [ ] **Step 4: Report + commit any incidental fixes**

No commit expected (validation-only task). If the build surfaced a bug in Task 1/2 code, fix it in those files, re-run the failing step, and commit the fix with a message explaining what the local proof caught.

---

### Task 4: Local linux proof for realtime + analytics

**Files:**
- No source changes. Produces `artifacts/{realtime,analytics}/<ver>/linux-arm64/rootfs` locally.

**Interfaces:**
- Consumes: Tasks 1–2 for both services.
- Produces: built rootfs trees for Task 5's scan.

- [ ] **Step 1: Build both linux-arm64 cells (concurrently, in background)**

Versions: read `version =` from `services/realtime/nix/default.nix` and `services/analytics/nix/default.nix` (do not assume). Launch both, poll both logs in-turn (same pattern as Task 3 Step 1 — sleep-loop + tail, never end the turn to wait):

```bash
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh realtime <ver> > /tmp/realtime-linux-build.log 2>&1 &
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh analytics <ver> > /tmp/analytics-linux-build.log 2>&1 &
```

Expected per service: full cell green; floor-check log contains `side-data ok`.

- [ ] **Step 2: Confirm artifact contents for both**

Same four checks as Task 3 Step 2, for each service (`zoneinfo bundled`, TZDIR guard in env.sh tail, `variants pruned`, size reported).

- [ ] **Step 3: Report**

Validation-only; commit only incidental fixes (as in Task 3 Step 4). No tamper re-test needed — mechanism already proven non-vacuous on pooler; the identical block hash (Task 2 Step 2) carries the proof across.

---

### Task 5: Verification sweep — iconv import scan + postgrest

**Files:**
- Modify: `docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md` (append a `## Sweep results` section)

**Interfaces:**
- Consumes: rootfs trees from Tasks 3–4; a locally built postgrest linux-arm64 rootfs (this task builds it).
- Produces: recorded sweep results; a STOP-AND-REPORT if postgrest imports iconv.

- [ ] **Step 1: Build postgrest linux-arm64 locally**

postgrest is image-derived (no compile), so this is quick. Version: read the usage of `scripts/ci-build-service.sh` and the tag in `services/postgrest/recipe.env` (`UPSTREAM_IMAGE`). Run the same background+poll pattern; expect the full cell green (it was green on main; this branch doesn't change postgrest).

- [ ] **Step 2: Scan all four linux rootfs trees for iconv imports**

```bash
docker run --rm -v "$PWD":/repo -w /repo ubuntu:24.04 bash -c '
  apt-get -qq update >/dev/null && apt-get -qq install -y binutils file >/dev/null
  hits=0
  for rootfs in artifacts/pooler/*/linux-arm64/rootfs artifacts/realtime/*/linux-arm64/rootfs artifacts/analytics/*/linux-arm64/rootfs artifacts/postgrest/*/linux-arm64/rootfs; do
    [ -d "$rootfs" ] || continue
    echo "== $rootfs"
    find "$rootfs" -type f | while read -r f; do
      file -b "$f" | grep -q "^ELF" || continue
      if readelf --dyn-syms -W "$f" 2>/dev/null | grep -E "UND +iconv(_open|_close)?(@|$)" >/dev/null; then
        echo "ICONV-IMPORT: $f"
      fi
    done
  done
  echo "scan complete"'
```

Expected: `scan complete` with zero `ICONV-IMPORT` lines. Decision rules (from the spec):
- Zero hits anywhere → no gconv bundling; record.
- Hits in pooler/realtime/analytics (host-glibc artifacts) → still no bundling (host gconv ships with host libc); record which binary and why it is safe.
- Hits in **postgrest** (the bundled-glibc artifact) → STOP AND REPORT to the orchestrator with the exact binary and symbols. Do not design or implement a fix in this task.

- [ ] **Step 3: Confirm the postgres facts for the docs note**

```bash
grep -n "with-system-tzdata" sources/postgres/nix/postgresql/generic.nix
grep -n "glibcLocalesMinimal" services/postgres/nix/packages/postgres.nix | head -3
grep -rn "LOCALE_ARCHIVE\|LOCPATH" services/postgres/ || echo "no locale env wiring (expected)"
```

Expected: `--with-system-tzdata` is guarded by `(!portable)`; `glibcLocalesMinimal` present in postgres.nix; no locale env wiring.

- [ ] **Step 4: Append `## Sweep results` to the spec and commit**

Append a dated section to `docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md` recording: the scan command, per-rootfs results, the postgres confirmations from Step 3, and the resulting decision (no gconv/locale bundling; postgrest clean or the reported exception).

```bash
git add docs/superpowers/specs/2026-07-09-glibc-runtime-side-data-design.md
git commit -m "docs: record the iconv/gconv sweep results (no consumers; no bundling)"
```

---

### Task 6: Docs — playbook, decision log, handoff, gotchas

**Files:**
- Modify: `NIX_PORTABLE_ARTIFACT_PLAYBOOK.md` (Linux-half section: add the zoneinfo/TZDIR block and the no-NSS/gconv/locale rationale, pointing at the spec)
- Modify: `HOST_NATIVE_PLAN.md` (decision log: one dated entry — side-data closed by evidence: tzdata bundled for BEAM trio, NSS/gconv/locale proven unnecessary at the 2.39 floor, floor checks extended)
- Modify: `docs/superpowers/plans/2026-07-09-portability-next-handoff.md` (PR-2 section: replace tasks 1–4 with a pointer to the spec + one-line outcome per decision; gotcha index: add the three new gotchas below)

**Interfaces:**
- Consumes: sweep results from Task 5.
- Produces: nothing downstream; PR-ready docs.

- [ ] **Step 1: Make the three edits**

Read each target section before editing; mirror the file's existing voice and formatting. New gotchas for the handoff index (verbatim content to convey, adapt phrasing to the list style):

```
- glibc >= 2.34 compiles nss_files/nss_dns into libc: bundling NSS modules for
  host-glibc artifacts is wrong (cross-glibc dlopen), not just unnecessary.
- Stock glibc ignores LOCALE_ARCHIVE (a Nix-glibc patch) and LOCPATH cannot
  read archive files — a bundled locale-archive is inert for host-glibc
  artifacts.
- Erlang never calls glibc iconv (pure-ERTS unicode): an iconv floor-check in
  a BEAM eval is unimplementable without a NIF.
```

- [ ] **Step 2: Verify and commit**

Skim the three diffs for contradictions with the spec, then:

```bash
git add NIX_PORTABLE_ARTIFACT_PLAYBOOK.md HOST_NATIVE_PLAN.md docs/superpowers/plans/2026-07-09-portability-next-handoff.md
git commit -m "docs: record the side-data contract (tzdata bundled; NSS/gconv/locale proven unnecessary)"
```

---

### Task 7: Final whole-branch review

Run the standard subagent-driven final review of the whole branch diff (`git diff main...HEAD`) on the strongest available model, per superpowers:requesting-code-review. Fix findings, commit, re-review if the fixes were non-trivial. Gate: no unresolved correctness findings before Task 8.

---

### Task 8: CI validation, results tables, PR

**Files:**
- Modify: `README.md` + `SLIM_IMAGES_REPORT.md` (generated table rows only, via the script)

**Interfaces:**
- Consumes: everything; a green forced dispatch is the linux gate for storage/pgmeta (their linux cells cannot build on this Mac).

- [ ] **Step 1: Push and dispatch**

```bash
git push -u origin claude/glibc-runtime-side-data-f0b0fb
gh workflow run service-artifacts.yml --ref claude/glibc-runtime-side-data-f0b0fb \
  -f services="pooler realtime analytics storage pgmeta" -f force=true
```

- [ ] **Step 2: Watch the run to completion (poll in-turn)**

```bash
gh run list --workflow=service-artifacts.yml --branch claude/glibc-runtime-side-data-f0b0fb --limit 1
# then: gh run watch <run-id> --exit-status   (or poll `gh run view <run-id>` in a sleep-loop)
```

Expected: all matrix cells green EXCEPT the known-failing `refresh results tables` job (org permission — ignore it, per handoff). If a floor-check cell fails, pull its log (`gh run view <run-id> --log-failed`), diagnose, fix, re-dispatch.

- [ ] **Step 3: Refresh results tables locally**

Quarantine first (the `--merge` trap: it refreshes EVERY service with a local `artifacts/` manifest):

```bash
mkdir -p /tmp/artifacts-quarantine
# postgrest was built locally only for the sweep — its row must not refresh:
mv artifacts/postgrest /tmp/artifacts-quarantine/ 2>/dev/null || true
# anything else present that this PR did not touch: quarantine it too; keep
# pooler, realtime, analytics, storage, pgmeta.
ls artifacts/
```

Then follow the PR-1 procedure: download the dispatch run's manifests (`gh run download <run-id>` — read `.github/workflows/service-artifacts.yml`'s upload layout and place them under `artifacts/<svc>/<ver>/<target>/manifest.json`), run:

```bash
scripts/update-results-tables.sh --merge
git add README.md SLIM_IMAGES_REPORT.md
git commit -m "docs: refresh results tables for the side-data artifacts"
git push
```

Expected: only the five touched services' rows change; BEAM linux rows grow by roughly the compressed zoneinfo size (~0.5 MiB — sanity-check the delta).

- [ ] **Step 4: Open the PR**

```bash
gh pr create --base main --title "glibc runtime side-data: bundle tzdata, prove NSS/TZ in floor checks" --body "<summary per repo PR style; cite the spec; note the evidence-based narrowing (no NSS/gconv/locale bundling) and the sweep results>

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

Restore the quarantined artifacts afterwards or delete them (report which).
