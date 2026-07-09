# glibc runtime side-data — design (PR 2 of the portability roadmap)

Date: 2026-07-09. Status: approved by user (brainstorm session).
Supersedes the PR-2 sketch in `docs/superpowers/plans/2026-07-09-portability-next-handoff.md`
(tasks 1/2/4 there were written before the evidence below existed; task 3's open
point is resolved here).

## Goal

No service may silently depend on host NSS/gconv/locale/tzdata files. "Silently"
is the operative word: failures must be either impossible at the measured floor,
or loud, or the data must be bundled. Bundling is a last resort — only for data
that is genuinely absent on floor-compliant hosts and has no glibc-version
coupling.

## Evidence (empirical, reproducible)

All verified on bare `ubuntu:24.04` (glibc 2.39-0ubuntu8.7 — exactly the Linux
floor and the floor-check image):

1. **NSS `files` and `dns` are compiled into `libc.so.6`** (moved in glibc
   2.33/2.34). With every `libnss_*.so*` deleted from the container, both
   `getent hosts <hosts-entry>` (files path, under `--network none`) and
   `getent hosts example.com` (dns path) still resolve. At floor ≥ 2.39 these
   code paths cannot be missing on a compliant host.
   Repro: `docker run --rm ubuntu:24.04 bash -c 'rm -f /usr/lib/*/libnss_*; getent hosts example.com'`
2. **gconv modules ship inside the host's libc package** — present in bare
   `ubuntu:24.04` (`/usr/lib/*/gconv/`). Wherever host glibc is, its gconv
   modules are too.
3. **`C.UTF-8` is built into glibc ≥ 2.35** — available with no locale archive
   or locale files at all.
4. **tzdata is genuinely absent on minimal hosts** — bare `ubuntu:24.04` has no
   `/usr/share/zoneinfo`. glibc degrades *silently* to UTC on a bad/missing TZ.
   This is the one real gap, and tzdata is pure data (zero glibc-version
   coupling).

Corrections to the handoff's premises, established from the tree:

- The "pooler NSS fix" does not exist in `services/pooler/nix/default.nix`. It
  is docker-image-era history: bundled in Phase 1 (`services/pooler/REPORT.md`
  ~L47), removed in Phase 2 in favor of the distroless base providing NSS
  (~L61). There is nothing to extend; the question was whether to *introduce*
  NSS bundling — answered no (below).
- Postgres is **not** a bundled-glibc artifact: `postgres-portable.nix` excludes
  `libc.so*`/`ld-linux*` (host glibc), skips `--with-system-tzdata` for the
  portable variant so PG ships its own `share/postgresql/timezone{,sets}`, and
  its bundled `glibcLocalesMinimal` is wired to nothing (no `LOCALE_ARCHIVE`/
  `LOCPATH` anywhere; stock host glibc ignores `LOCALE_ARCHIVE` — that env var
  is a Nix-glibc patch — and `LOCPATH` cannot read archive files).
- Postgrest (linux-arm64, `SPLIT_BUNDLED_GLIBC`) is the only bundled-glibc
  artifact and already carries `libnss_*` in the split glibc family.

## Decisions (user-approved)

1. **No NSS bundling anywhere.** Built into libc at the floor; bundling
   nix-built modules for the *host* libc to dlopen would add cross-glibc
   coupling (the pin's glibc is newer than 2.39) plus `LD_LIBRARY_PATH`/legacy
   `DT_RPATH` hacks, because libc's dlopen ignores the executable's
   `DT_RUNPATH`. Floor-check gains an execution proof instead (below).
2. **No audit WARN** for NSS/side-data. NSS consumption is statically invisible
   (`getaddrinfo` lives in libc), and "no NSS modules bundled" is now the
   *correct* state. Execution proof over static heuristics — PR #14 philosophy.
3. **tzdata bundled for the BEAM trio only** (realtime, pooler, analytics).
   Node duo skipped: V8/ICU carries its own tz data. Postgres skipped: PG ships
   its own. Static Go (auth) and edge-runtime unaffected.
4. **gconv/locale: verification sweep, not speculative bundling** (decision
   rules below). Nothing known consumes glibc iconv: Erlang's unicode machinery
   is pure ERTS (an "iconv conversion in the BEAM evals" is unimplementable
   without a NIF), Node uses ICU, PG uses its own conversion tables, GHC's
   default UTF-8 path uses libc built-in conversions.

## Design

### 1. tzdata + TZDIR for the BEAM trio

In each of `services/{realtime,pooler,analytics}/nix/default.nix`, in the
**Linux fixup half only** (macOS always ships `/usr/share/zoneinfo`):

- Copy the pinned nixpkgs `tzdata`'s `share/zoneinfo` into the rootfs at
  `share/zoneinfo` (~450 KB compressed per artifact; pure data).
- Append to every generated `releases/*/env.sh` (sourced by `bin/<release>` on
  every invocation, after `RELEASE_ROOT` is set — same loop shape as the
  existing disksup `vm.args` block, byte-identical across the three files):

```sh
if [ -z "${TZDIR:-}" ] && [ -d "$RELEASE_ROOT/share/zoneinfo" ]; then
  export TZDIR="$RELEASE_ROOT/share/zoneinfo"
fi
```

User-set `TZDIR` wins. Env lives in the artifact (release env script), not the
CLI — per the standing decision.

### 2. FLOOR_CHECK_CMD extensions (extend, never replace)

- **BEAM ×3** (`services/<svc>/recipe.env`): extend each existing eval with
  - `{:ok, _} = :inet.gethostbyname(~c"slim-floor-check")` — resolves the
    existing `--add-host slim-floor-check=127.0.0.1` name under
    `--network none`, through Erlang's default `native` lookup →
    `inet_gethost` port binary → `getaddrinfo` → glibc NSS. This is the entire
    machinery that failed in the `:nxdomain` incident, minus only the DNS wire
    protocol — which lives in the same libc as the proven files path at ≥ 2.34
    (record this reasoning as a recipe comment).
  - With `TZ=America/New_York` added to the check's env: assert
    `abs(gregorian_seconds(local_time) − gregorian_seconds(universal_time)) ≥ 3*3600`.
    New York is never UTC; missing/unusable tzdata silently yields UTC; the
    ≥ 3 h form dodges second-boundary races. This exercises the bundled
    `share/zoneinfo` via the env.sh `TZDIR` (floor-check invokes
    `bin/<release>` directly, which sources env.sh).
- **Node duo**: append a `dns.lookup("slim-floor-check", ...)` (libuv →
  `getaddrinfo`) to the existing `node --version` + require-every-`.node`
  checks.
- **postgres/postgrest/auth/edge-runtime**: unchanged.

### 3. Verification sweep (plan tasks with decision rules)

- Scan every service's artifact ELFs for dynamic imports of `iconv_open` (and
  `iconv`, `iconv_close`). Expected: none.
  - If none: bundle no gconv anywhere; record the scan result in docs.
  - If a host-glibc artifact imports it: still no bundling — host gconv ships
    with host libc (evidence #2); document.
  - If **postgrest** (bundled glibc) imports it beyond built-in conversions:
    that is the one real mismatch case (bundled libc reading host gconv
    modules) — only then design a fix (bundle the *same-image* glibc's gconv
    dir + `GCONV_PATH` via a new `services/postgrest/wrapper.sh`, which the
    harness already supports).
- Confirm in the postgres docs note: PG-owned tzdata present in the rootfs,
  `glibcLocalesMinimal` unwired-by-design (shared with non-portable variants —
  leave the nix expression untouched).

### 4. Docs

- Record the NSS built-in contract and evidence (this file is the canonical
  record; add a pointer + short version to the portability docs the repo
  already keeps, e.g. HOST_NATIVE_PLAN.md decision log and the gotcha index).
- Update the handoff's PR-2 section to point here.
- Gotcha additions: glibc ≥ 2.34 compiles nss_files/nss_dns into libc (bundling
  NSS modules for host glibc is wrong, not just unnecessary); stock glibc
  ignores `LOCALE_ARCHIVE` (Nix patch) and `LOCPATH` can't read archives;
  Erlang never calls glibc iconv.

## Validation

- BEAM trio: build linux-arm64 artifacts locally (docker nix path) and run
  `scripts/floor-check-linux.sh` — must prove resolution + TZ delta with the
  new checks; also run once with the tzdata copy deliberately removed to see
  the TZ check FAIL (guard against a vacuous check).
- Node duo: linux cells cannot build on this Mac — gated by a forced
  `service-artifacts.yml` dispatch (`-f services="realtime pooler analytics storage pgmeta" -f force=true`).
- Darwin: BEAM artifact smokes locally (env.sh append must not break darwin
  even though TZDIR dir is absent there — the `-d` guard covers it).
- Results tables refreshed locally via `scripts/update-results-tables.sh
  --merge` after quarantining stale local `artifacts/` dirs (storage/pgmeta
  darwin fixtures currently present — the known `--merge` trap).
- `bash -n` every touched script; bash-3.2 rules apply to anything CI runs on
  macOS.

## Non-goals

- NSS/gconv/locale bundling (evidence-based; see Decisions).
- Audit WARN for side-data (skipped by user decision).
- Darwin side-data work, musl targets, studio (standing non-goals).
- BEAM floor 2.39 → 2.38 (that is PR 3).

## Risks

- Erlang `native` lookup assumption: `:inet.gethostbyname` must go through
  getaddrinfo. No `ERL_INETRC` exists in these releases; verified at execution
  time by the local floor-check runs (a wrong assumption fails loudly there).
- `env.sh` append point: relies on `RELEASE_ROOT` being set before env.sh is
  sourced — confirmed in the generated `bin/.<release>-wrapped` scripts.
- tzdata staleness: pinned nixpkgs tzdata ages with the pin; acceptable — same
  provenance story as every other bundled dependency, refreshed on pin bumps.
