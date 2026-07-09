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

## Sweep results (2026-07-09)

Ran the verification sweep from Design §3 against the four linux-arm64 rootfs
trees available (`artifacts/{pooler,realtime,analytics,postgrest}/*/linux-arm64/rootfs`;
postgrest's tree was built for this sweep — image-derived, no compile,
`SOURCE_REF=v14.14`).

Scan command (`ubuntu:24.04`, `binutils`+`file`, `readelf --dyn-syms`):

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

Per-rootfs results:

- **pooler** (2.9.10, host-glibc artifact): one hit, `dylib/libstdc++.so.6`
  (libstdc++'s locale-facet code imports iconv, not the pooler binary). Host
  gconv ships with host libc (evidence #2) → no bundling.
- **realtime** (2.112.6, host-glibc artifact): same hit, same file
  (`dylib/libstdc++.so.6`), same reasoning → no bundling.
- **analytics** (1.46.0, host-glibc artifact): same hit, same file
  (`dylib/libstdc++.so.6`), same reasoning → no bundling.
- **postgrest** (v14.14, the one bundled-glibc artifact): hit in `bin/postgrest`
  itself — `iconv@GLIBC_2.17`, `iconv_open@GLIBC_2.17`, `iconv_close@GLIBC_2.17`,
  all `UND` (confirmed with a targeted `readelf --dyn-syms -W` follow-up). This
  is the one real mismatch case flagged in Design §3.

### Architectural correction (supersedes the Design §3 wrapper/`GCONV_PATH` sketch)

The sketch in Design §3 assumed a bare-host run of the bundled glibc would need
`GCONV_PATH` pointed at a same-image gconv copy via a new
`services/postgrest/wrapper.sh`. That assumption doesn't hold, per the
`SPLIT_BUNDLED_GLIBC` comment block in `scripts/build-artifact-from-image.sh:132-143`:
on a bare host, the **host loader pairs with the host glibc** (the split step's
whole purpose — `lib/<triplet>` is the loader's own standard search path, so a
bare-host run never touches the bundled libc at all). Host gconv is already
present there (evidence #2) — no gap. The actual gap is scratch-image-only:
inside the Docker image, the *bundled* libc is what runs, and its compiled-in
gconv path (`/usr/lib/<triplet>/gconv`) is a path inside the artifact itself
once extracted at `/` — where no gconv modules existed before this fix. No env
var, no wrapper: the fix is to make that exact path resolve to real modules.

### Implemented fix

`services/postgrest/recipe.env`: added `/usr/lib/aarch64-linux-gnu/gconv` and
`/usr/lib/x86_64-linux-gnu/gconv` to `OPTIONAL_INCLUDE_PATHS` (optional because
the amd64 upstream image is a static-binary scratch image with no gconv dir —
must not fail the build there; confirmed this build only found the aarch64
copy, as expected when building the arm64 target). `OPTIONAL_INCLUDE_PATHS` has
no `_JSON` twin in this or any other recipe — `scripts/build-artifact-from-image.sh`
never reads one (only `INCLUDE_PATHS_JSON`/`AUTO_ELF_BINARIES_JSON` feed the
manifest), so none was added.

This ships the gconv modules from `SOURCE_IMAGE` itself — the exact same glibc
build as the bundled libc, so provenance matches exactly (no cross-glibc
coupling, unlike the rejected NSS-bundling idea in Decisions #1). Verified
`scripts/prune-runtime-tree.sh` does not touch it: it only deletes specific
extensions (`*.map/*.d.ts/*.debug/*.a/*.la/...`, none matching `.so` modules or
the extension-less `gconv-modules` config files) and specific directory names
(`.cache/.git/test/docs/examples/benchmark/...`, not `gconv`). Verified
`SPLIT_BUNDLED_GLIBC`'s glibc-family move (`scripts/build-artifact-from-image.sh:162-180`)
only moves specific `lib*.so*`/`ld-linux*.so*` filenames out of
`usr/lib/<triplet>`, not directories — the `gconv/` subdirectory is untouched
and stays at `usr/lib/aarch64-linux-gnu/gconv`, its compiled-in path.

Rebuilt postgrest linux-arm64 (`TARGET_OS=linux ARCH=arm64
scripts/ci-build-service.sh postgrest v14.14`): full green cell (artifact
build, distribution archive, checksums, Docker image build, image smoke —
`postgrest smoke passed` — runtime metrics, gzip size measurement). Confirmed
in the rebuilt rootfs: `usr/lib/aarch64-linux-gnu/gconv/` contains 256 entries
— `gconv-modules` (3.8K config), `gconv-modules.cache` (26.4K), the
`gconv-modules.d/` directory, and 253 `.so` conversion modules (e.g.
`BIG5.so`, `CP1252.so`) — and the split step's loader/libc family
(`lib/ld-linux-aarch64.so.1`, `lib/aarch64-linux-gnu/libc.so.6`) landed at its
usual split location, confirming the gconv dir was left alone at its own path.

Artifact size delta (linux-arm64, from `manifest.json` before/after):
uncompressed rootfs 95.5 → 114.8 MiB (+19.3 MiB, matching the source image's
gconv closure size); zstd archive 14.4 → 15.9 MiB (+1.5 MiB compressed);
gzip-compressed Docker image 20.3 → 23.6 MiB (+3.3 MiB).

**This fix cannot be exercised by `FLOOR_CHECK_CMD` by design.** Floor-check
runs the bare-host path (`"$ROOTFS/bin/postgrest" --example`), which — per the
architectural correction above — pairs the host loader with host glibc and
never touches the bundled modules at all. The bundled gconv only serves the
scratch Docker image path, which floor-check does not exercise. Correctness
here rests on same-image provenance (the modules come from the identical
glibc build as the bundled libc that dlopens them) plus the presence check
performed during this sweep, not on an executable proof.

### Postgres facts (Design §3, second bullet)

```
$ grep -n "with-system-tzdata" sources/postgres/nix/postgresql/generic.nix
181:      ++ lib.optionals (!portable) [ "--with-system-tzdata=${tzdata}/share/zoneinfo" ]

$ grep -n "glibcLocalesMinimal" services/postgres/nix/packages/postgres.nix | head -3
7:      glibcLocalesMinimal = pkgs.glibcLocales.override {
197:            glibcLocalesMinimal
247:          # glibcLocalesMinimal on Linux (initdb locale support).

$ grep -rn "LOCALE_ARCHIVE\|LOCPATH" services/postgres/ || echo "no locale env wiring (expected)"
no locale env wiring (expected)
```

Confirms the Evidence-section claims: `--with-system-tzdata` is skipped for the
portable variant (guarded by `(!portable)`, so PG ships its own
`share/postgresql/timezone{,sets}`); `glibcLocalesMinimal` is present in the
Nix expression but unwired (no `LOCALE_ARCHIVE`/`LOCPATH` env anywhere under
`services/postgres/`).

### Resulting decision

- No gconv bundling for the BEAM trio or for any other host-glibc artifact —
  their only iconv importer is `libstdc++.so.6`, which reads host gconv
  (evidence #2, unaffected by any nixpkgs pin skew since it's the *host's*
  gconv, not a bundled one).
- postgrest ships its own gconv modules (same-image provenance, via
  `OPTIONAL_INCLUDE_PATHS`) to close the one real mismatch: its bundled libc's
  compiled-in gconv path is otherwise empty inside the scratch Docker image.
  No wrapper, no `GCONV_PATH`, no other env var — supersedes the Design §3
  sketch.
- Postgres needs nothing further: it owns its own tzdata and never wires
  `glibcLocalesMinimal` into anything glibc would read.

## Risks

- Erlang `native` lookup assumption: `:inet.gethostbyname` must go through
  getaddrinfo. No `ERL_INETRC` exists in these releases; verified at execution
  time by the local floor-check runs (a wrong assumption fails loudly there).
- `env.sh` append point: relies on `RELEASE_ROOT` being set before env.sh is
  sourced — confirmed in the generated `bin/.<release>-wrapped` scripts.
- tzdata staleness: pinned nixpkgs tzdata ages with the pin; acceptable — same
  provenance story as every other bundled dependency, refreshed on pin bumps.
