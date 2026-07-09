# Node Bundling (storage + pg-meta) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bundle the pinned nixpkgs Node 24 runtime into the storage and pg-meta archives so both run as-extracted with zero external runtime, per `docs/superpowers/specs/2026-07-09-node-bundling-design.md`.

**Architecture:** A new repo-owned nix derivation (`nix/portable-node/default.nix`) stages `nodejs_24` plus its non-glibc dylib closure into a portable layout using the proven pooler playbook (patchelf + `$ORIGIN` rpaths on linux, `install_name_tool` + ad-hoc codesign on darwin). Each service's `build-host.sh` (which builds ALL targets — linux CI runners have nix) copies it to `<rootfs>/node/` and the `bin/<svc>` wrapper prefers it. Recipes gain a `FLOOR_CHECK_CMD` execution proof, drop `runtime_requires`, and the Docker images switch to `distroless/base-debian13` + the bundled node.

**Tech Stack:** bash, nix (pinned nixpkgs `ac62194c`), patchelf, install_name_tool/codesign, Docker, GitHub Actions.

## Global Constraints

- Shared nixpkgs pin: `https://github.com/NixOS/nixpkgs/archive/ac62194c3917d5f474c1a844b6fd6da2db95077d.tar.gz`, sha256 `0v6bd1xk8a2aal83karlvc853x44dg1n4nk08jg3dajqyy0s98np` (`scripts/nixpkgs-pin.sh`). Repo-owned nix files embed the pin themselves (self-contained by design).
- Floors (gated by `scripts/audit-portable-artifact.sh`): linux glibc ≤ **2.39**, macOS ≤ **14.0**. glibc family is NEVER bundled (host-provided; exclusion list in `scripts/lib.sh` `portable_host_libs_json` and pooler's `should_exclude`).
- DT_RUNPATH is NOT transitive: every bundled `.so` needs its own `$ORIGIN` rpath.
- GNU strip corrupts patchelf-ed ELFs: strip BEFORE patchelf, never after.
- macOS CI runs repo scripts under **bash 3.2**: run `/bin/bash -n` on every touched script; no `${var,,}`, no assoc arrays, no apostrophes in comments inside `$()`, no case-parens inside `$()`.
- Archives must run as-extracted; no CLI-side relocation logic (settled user decision).
- All shell edits in this repo pass `shellcheck` conventions already in place (source hints kept).
- Local machine is darwin-arm64 with Docker Desktop (runs linux/arm64 containers natively). Linux artifacts for these two services CANNOT be built locally (`build-host.sh` refuses cross-OS); linux validation happens via the CI dispatch in Task 7.
- Commit after every task; messages follow repo style (`storage: …`, `pgmeta: …`, `scripts: …`, `docs: …`), ending with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: pg-meta on Node 24 (compatibility gate)

Latest Node LTS is 24 (Node 25 is non-LTS; 26 goes LTS 2026-10). Storage already builds and smokes on the pin's `nodejs_24`; pg-meta is on `nodejs_20`. The bundled runtime must match the build runtime (native-addon ABI / NODE_MODULE_VERSION), so pg-meta moves to `nodejs_24` — gated on its smoke passing.

**Files:**
- Modify: `services/pgmeta/build-host.sh:24-26`
- Modify: `services/pgmeta/smoke.sh:25-27,41-43`

**Interfaces:**
- Produces: pgmeta builds and smokes on `nodejs_24`; later tasks assume Node 24 everywhere.

- [ ] **Step 1: Bump the build runtime**

In `services/pgmeta/build-host.sh` replace lines 24-26:

```bash
# Same Node major as the Docker builder (node:20).
log "resolving nodejs_20 from pinned nixpkgs"
node_store="$(nixpkgs_build_attr nodejs_20)"
```

with:

```bash
# Latest Node LTS, same major as the bundled runtime (nix/portable-node).
log "resolving nodejs_24 from pinned nixpkgs"
node_store="$(nixpkgs_build_attr nodejs_24)"
```

- [ ] **Step 2: Bump the smoke runtime**

In `services/pgmeta/smoke.sh` replace line 27 comment tail `pinned to the same major as the Docker runtime image (node 20).` with `pinned to the same major as the build runtime (node 24).` and replace lines 42-43:

```bash
    log "resolving nodejs_20 from pinned nixpkgs for the smoke runtime"
    SUPABASE_NODE="$(nixpkgs_build_attr nodejs_20)/bin/node"
```

with:

```bash
    log "resolving nodejs_24 from pinned nixpkgs for the smoke runtime"
    SUPABASE_NODE="$(nixpkgs_build_attr nodejs_24)/bin/node"
```

(This SUPABASE_NODE block is removed entirely by Task 5; the bump keeps the compat test honest meanwhile.)

- [ ] **Step 3: Syntax-check**

Run: `/bin/bash -n services/pgmeta/build-host.sh services/pgmeta/smoke.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Run the darwin cell (build + audit + floors + artifact smoke)**

First run `scripts/ci-build-service.sh` with no args to confirm the usage/version argument (version is the recipe `SOURCE_REF`, `v0.96.6`, unless usage says otherwise). Then:

Run: `TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh pgmeta v0.96.6`
Expected: build succeeds on node 24 (`using v24.x` in the log), audit passes, smoke hits `/health` 200, exit 0. Requires Docker running (smoke starts postgres).

**If the smoke fails on Node 24:** STOP, do not work around it. Report the failure output — the fallback (newest passing LTS) is an orchestrator decision per the design's D1.

- [ ] **Step 5: Commit**

```bash
git add services/pgmeta/build-host.sh services/pgmeta/smoke.sh
git commit -m "pgmeta: build and smoke on Node 24 (latest LTS)"
```

---

### Task 2: `nix/portable-node` derivation + pin helper

**Files:**
- Create: `nix/portable-node/default.nix`
- Modify: `scripts/nixpkgs-pin.sh` (add `nixpkgs_build_file` helper after `nixpkgs_build_attr`)

**Interfaces:**
- Produces: `nixpkgs_build_file FILE` → prints the store path of the built derivation; `nix-build nix/portable-node/default.nix` output layout: `bin/node` (+ `dylib/*` when the closure needs it). Task 3 consumes both.

- [ ] **Step 1: Write the derivation**

Create `nix/portable-node/default.nix`. Before writing, read `services/pooler/nix/default.nix:135-330` — the postFixup below is that playbook adapted for a single binary; keep the shell idioms identical where shown. Also read pooler's file top (lines 1-60) to mirror `mkDerivation` argument conventions if they differ from this sketch — the postFixup bodies below are normative, the wrapper attrset should follow pooler's style:

```nix
# Portable Node runtime bundle: the pinned nixpkgs nodejs_24 binary plus its
# non-glibc dylib closure, patched to run from any extraction path on a plain
# host (no /nix/store). Playbook: NIX_PORTABLE_ARTIFACT_PLAYBOOK.md; reference
# implementation: services/pooler/nix/default.nix postFixup.
#
# Self-contained pin — keep in sync with scripts/nixpkgs-pin.sh.
let
  nixpkgs = fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/ac62194c3917d5f474c1a844b6fd6da2db95077d.tar.gz";
    sha256 = "0v6bd1xk8a2aal83karlvc853x44dg1n4nk08jg3dajqyy0s98np";
  };
in
{ pkgs ? import nixpkgs { } }:

let
  inherit (pkgs) lib;
  node = pkgs.nodejs_24;
in
pkgs.stdenv.mkDerivation {
  pname = "portable-node";
  version = node.version;

  dontUnpack = true;
  # Stripping and rpath surgery are done by hand below, in the safe order
  # (strip BEFORE patchelf); keep the generic fixups away from the result.
  dontStrip = true;
  dontPatchELF = true;

  nativeBuildInputs = [ pkgs.file pkgs.python3 ]
    ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf pkgs.binutils ];

  installPhase = ''
    mkdir -p $out/bin
    cp -L ${node}/bin/node $out/bin/node
    chmod u+w $out/bin/node
  '';

  postFixup = lib.optionalString pkgs.stdenv.isLinux ''
    <LINUX BLOCK>
  '' + lib.optionalString pkgs.stdenv.isDarwin ''
    <DARWIN BLOCK>
  '';
}
```

`<LINUX BLOCK>` — copy pooler's linux postFixup (`services/pooler/nix/default.nix:144-237`) verbatim (`rootfs="$out"`, `dylib_dir`, `interp` case, `is_elf`, `elf_files`, `should_exclude`, `nix_store_deps`, the 8-iteration closure loop, the patch loop, the ldd audit) with exactly ONE change: split pooler's combined patch+strip loop into strip-first-then-patch:

```sh
# Strip BEFORE patchelf (GNU strip corrupts patchelf-ed binaries).
for elf in $(elf_files); do
  strip --strip-unneeded "$elf" 2>/dev/null || true
done
for elf in $(elf_files); do
  rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))" "$dylib_dir" "$elf")"
  if patchelf --print-interpreter "$elf" >/dev/null 2>&1; then
    patchelf --set-interpreter "$interp" "$elf" 2>/dev/null || true
  fi
  patchelf --set-rpath "\$ORIGIN/$rel" "$elf" 2>/dev/null || true
done
```

(The `\$ORIGIN` escaping inside the nix string must match pooler's — check how pooler line 210 escapes it in the .nix source and do the same.)

`<DARWIN BLOCK>` — copy pooler's darwin postFixup (`services/pooler/nix/default.nix:239-324`) verbatim: `is_macho`, `macho_files`, `nix_store_deps` (otool variant), the closure loop, the `install_name_tool` id/change/add_rpath/delete_rpath loop, `strip -x`, `codesign --force --sign -`, and the otool audit. Skip pooler's final `grep -rl /nix/store bin/ releases/ erts-*` block (BEAM-specific); instead end with:

```sh
if grep -rl "/nix/store" "$rootfs/bin" 2>/dev/null; then
  echo "portable node references /nix/store" >&2
  exit 1
fi
```

Note: pooler's darwin block uses no extra nativeBuildInputs for otool/install_name_tool/codesign (they come from the darwin stdenv) — mirror whatever pooler's `nativeBuildInputs` actually lists; if pooler adds darwin tools explicitly, add the same ones here.

- [ ] **Step 2: Add the file-build helper to the pin script**

In `scripts/nixpkgs-pin.sh`, extend the header comment's "Provides:" list with `nixpkgs_build_file FILE -> prints the store path of the built derivation in FILE` and append after `nixpkgs_build_attr`:

```bash
nixpkgs_build_file() {
  local file="$1"
  PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH" \
    nix-build --no-out-link "$file"
}
```

- [ ] **Step 3: Syntax-check**

Run: `/bin/bash -n scripts/nixpkgs-pin.sh`
Expected: exit 0.

- [ ] **Step 4: Build and verify portability locally (darwin-arm64)**

```bash
source scripts/nixpkgs-pin.sh
out="$(nixpkgs_build_file nix/portable-node/default.nix)"
echo "$out"; ls -la "$out/bin" "$out/dylib" 2>/dev/null
# no store refs in load commands:
otool -L "$out/bin/node"
otool -l "$out/bin/node" | grep -A2 LC_RPATH || true
# runs from a copied location (the actual portability claim):
rm -rf /tmp/pn-test && mkdir -p /tmp/pn-test && cp -R "$out"/. /tmp/pn-test/ && chmod -R u+w /tmp/pn-test
/tmp/pn-test/bin/node --version
/tmp/pn-test/bin/node -e 'console.log("portable ok", process.version)'
codesign --verify --deep /tmp/pn-test/bin/node && echo "signature ok"
```

Expected: `otool -L` shows NO `/nix/store` paths (only `/usr/lib/...`, `/System/...`, and `@rpath/...` if a dylib dir exists); node prints `v24.x`; signature verifies. If `dylib/` is empty on darwin that is fine (nixpkgs may link node against system libs only) — the linux CI build is where the closure matters.

- [ ] **Step 5: Commit**

```bash
git add nix/portable-node/default.nix scripts/nixpkgs-pin.sh
git commit -m "nix: add the portable-node runtime bundle (pinned nodejs_24, pooler playbook)"
```

---

### Task 3: Bundle the runtime into both rootfs + new wrapper order

**Files:**
- Modify: `services/storage/build-host.sh` (header comment lines 3-12; node bundling after line 83; wrapper heredoc lines 85-104)
- Modify: `services/pgmeta/build-host.sh` (header comment lines 3-10; node bundling after line 65; wrapper heredoc lines 67-86)

**Interfaces:**
- Consumes: `nixpkgs_build_file` from Task 2 (already sourced via `scripts/nixpkgs-pin.sh` in both scripts).
- Produces: `<rootfs>/node/bin/node` in every artifact; wrapper resolution `SUPABASE_NODE` → `$SCRIPT_DIR/../node/bin/node` → PATH. Tasks 4-5 rely on the `node/` path and this order.

- [ ] **Step 1: storage — bundle + re-sign + new wrapper**

In `services/storage/build-host.sh`:

(a) Replace the header comment's Option A sentence (lines 9-12, starting `The Node runtime is NOT bundled…`) with:

```bash
# The pinned Node runtime IS bundled (nix/portable-node) at rootfs node/;
# bin/storage resolves SUPABASE_NODE -> bundled node -> PATH. The archive is
# fully self-contained (no runtime_requires).
```

(b) After line 83 (`cp -R migrations "$ROOTFS/app/migrations"`), insert:

```bash
log "bundling portable node runtime (nix/portable-node)"
node_bundle="$(nixpkgs_build_file "$ROOT_DIR/nix/portable-node/default.nix")"
mkdir -p "$ROOTFS/node"
cp -R "$node_bundle"/. "$ROOTFS/node/"
chmod -R u+w "$ROOTFS/node"
if [[ "$TARGET_OS" == "darwin" ]]; then
  # Nix sandbox codesigning can emit signatures that fail OFF the build
  # machine (the libiconv incident); re-sign ad hoc after copying out of
  # the store, mirroring scripts/build-artifact-from-nix.sh.
  find "$ROOTFS/node" -type f -print0 | while IFS= read -r -d '' macho; do
    file "$macho" 2>/dev/null | grep -q "Mach-O" || continue
    codesign --force --sign - "$macho"
  done
fi
```

Before writing this, read the signature-repair block at `scripts/build-artifact-from-nix.sh:245-270`; if it verifies-then-resigns or handles extra cases, mirror its exact approach instead of the unconditional re-sign above.

(c) Replace the wrapper heredoc body (lines 86-103 inside `<<'WRAPPER'`) with:

```sh
#!/bin/sh
# Thin launcher for the self-contained artifact. Runtime resolution:
# SUPABASE_NODE (explicit override), then the bundled runtime, then PATH.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_BIN="${SUPABASE_NODE:-}"
if [ -z "$NODE_BIN" ] && [ -x "$SCRIPT_DIR/../node/bin/node" ]; then
  NODE_BIN="$SCRIPT_DIR/../node/bin/node"
fi
if [ -z "$NODE_BIN" ]; then
  NODE_BIN="$(command -v node || true)"
fi
if [ -z "$NODE_BIN" ]; then
  echo "storage: no Node runtime found; set SUPABASE_NODE" >&2
  exit 1
fi
cd "$SCRIPT_DIR/../app"
exec "$NODE_BIN" dist/start/server.js "$@"
```

- [ ] **Step 2: pgmeta — same three edits**

In `services/pgmeta/build-host.sh`: (a) replace the header's Option A sentence (lines 7-10) with the same new text (s/storage/pgmeta/); (b) insert the identical bundling block after line 65 (`cp -R node_modules "$ROOTFS/app/node_modules"`); (c) replace the wrapper heredoc body with the same wrapper (`pgmeta:` in the error message, `exec "$NODE_BIN" dist/server/server.js "$@"` as the last line).

- [ ] **Step 3: Syntax-check**

Run: `/bin/bash -n services/storage/build-host.sh services/pgmeta/build-host.sh`
Expected: exit 0.

- [ ] **Step 4: Build both darwin cells; verify the bundle**

Run: `TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh storage v1.62.6`
Run: `TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh pgmeta v0.96.6`
Expected: both green (audit + floors + smoke; the smokes still inject SUPABASE_NODE until Task 5 — that is fine). The audit now scans `node/bin/node`; if the macOS floor gate rejects it (> 14.0), STOP and report — that contradicts the design's floor assumption and is an orchestrator decision.

Then verify the artifact layout (adjust version dir if `ls artifacts/storage/` differs):

```bash
rootfs="artifacts/storage/v1.62.6/darwin-arm64/rootfs"
"$rootfs/node/bin/node" --version                      # v24.x
SUPABASE_NODE= "$rootfs/bin/storage" 2>&1 | head -5 || true   # must NOT print "no Node runtime found"
otool -L "$rootfs/node/bin/node" | grep -c /nix/store  # 0
```

- [ ] **Step 5: Commit**

```bash
git add services/storage/build-host.sh services/pgmeta/build-host.sh
git commit -m "storage,pgmeta: bundle the portable node runtime; wrapper prefers it"
```

---

### Task 4: Recipes (floor check, no runtime_requires) + Docker images on the bundled node

**Files:**
- Modify: `services/storage/recipe.env`
- Modify: `services/pgmeta/recipe.env`
- Modify: `services/storage/Dockerfile.slim`
- Modify: `services/pgmeta/Dockerfile.slim`
- Modify: `scripts/floor-check-linux.sh:19-21` (usage text only)

**Interfaces:**
- Consumes: `<rootfs>/node/bin/node` from Task 3.
- Produces: `FLOOR_CHECK_CMD` set for both services (consumed by `scripts/floor-check-linux.sh` via `bash -c "set -euo pipefail; $FLOOR_CHECK_CMD"` in the floor container with `ROOTFS=/rootfs`, read-only mount, no network); `RUNTIME_REQUIRES` gone (manifest `runtime_requires` becomes `null` automatically — `scripts/build-artifact-from-source.sh:217` uses `${RUNTIME_REQUIRES:-}`); images run `/node/bin/node`.

- [ ] **Step 1: storage recipe**

In `services/storage/recipe.env`: replace lines 3-6 (the header comment) with:

```bash
# Native-first (HOST_NATIVE_PLAN.md): services/storage/build-host.sh builds
# the rolldown JS bundle + the bundled Node runtime (nix/portable-node) +
# bin/storage wrapper for every target; the Docker image is derived from the
# artifact (app/ + node/) on the distroless base image via Dockerfile.slim.
```

Replace lines 11-14 (the skip comment + `RUNTIME_REQUIRES="node>=20"`) with:

```bash
# Execution proof at the glibc floor (scripts/floor-check-linux.sh): the
# bundled node must load, and every bundled native addon (fs-xattr) must
# dlopen, on a bare glibc-2.39 host. No runtime_requires: nothing external.
FLOOR_CHECK_CMD='"$ROOTFS/node/bin/node" --version && addons=$(find "$ROOTFS/app/node_modules" -type f -name "*.node") && [ -n "$addons" ] && for a in $addons; do echo "loading $a"; "$ROOTFS/node/bin/node" -e "require(process.argv[1])" "$a"; done'
```

Replace line 17-18:

```bash
BASE_IMAGE="${BASE_IMAGE:-gcr.io/distroless/nodejs24-debian13:nonroot}"
ENTRYPOINT_JSON='["/nodejs/bin/node"]'
```

with:

```bash
BASE_IMAGE="${BASE_IMAGE:-gcr.io/distroless/base-debian13:nonroot}"
ENTRYPOINT_JSON='["/node/bin/node"]'
```

- [ ] **Step 2: pgmeta recipe — same three edits**

Header comment: same new text with `services/pgmeta/build-host.sh`, `bin/pgmeta`, "the JS bundle" instead of "the rolldown JS bundle". Skip-comment + `RUNTIME_REQUIRES` replaced by the same `FLOOR_CHECK_CMD` line with the addon name swapped in the comment (`(the sentry cpu profiler)` instead of `(fs-xattr)`) — the command string itself is identical. `BASE_IMAGE` → `gcr.io/distroless/base-debian13:nonroot`, `ENTRYPOINT_JSON` → `'["/node/bin/node"]'`.

- [ ] **Step 3: Dockerfiles**

`services/storage/Dockerfile.slim` becomes:

```dockerfile
# syntax=docker/dockerfile:1.7
# Derived image: distroless base + the portable artifact's app/ tree and its
# bundled Node runtime (bin/storage host wrapper is unused in Docker — the
# entrypoint execs the bundled node directly).
ARG BASE_IMAGE=gcr.io/distroless/base-debian13:nonroot
FROM ${BASE_IMAGE}
ARG ARTIFACT_ROOT
WORKDIR /app
ENV NODE_ENV=production
COPY ${ARTIFACT_ROOT}/app/ /app/
COPY ${ARTIFACT_ROOT}/node/ /node/
EXPOSE 5000
ENTRYPOINT ["/node/bin/node"]
CMD ["dist/start/server.js"]
```

`services/pgmeta/Dockerfile.slim` becomes:

```dockerfile
# syntax=docker/dockerfile:1.7
# Derived image: distroless base + the portable artifact's app/ tree and its
# bundled Node runtime (bin/pgmeta host wrapper is unused in Docker — the
# entrypoint execs the bundled node directly).
ARG BASE_IMAGE=gcr.io/distroless/base-debian13:nonroot
FROM ${BASE_IMAGE}
ARG ARTIFACT_ROOT
WORKDIR /usr/src/app
ENV PG_META_PORT=8080
COPY ${ARTIFACT_ROOT}/app/ /usr/src/app/
COPY ${ARTIFACT_ROOT}/node/ /node/
EXPOSE 8080
ENTRYPOINT ["/node/bin/node"]
CMD ["dist/server/server.js"]
```

- [ ] **Step 4: floor-check usage text**

In `scripts/floor-check-linux.sh` lines 19-21, replace:

```
A recipe without FLOOR_CHECK_CMD is skipped WITH A LOG LINE — silence must
never read as coverage (Node-runtime services are checked by the CLI's
runtime_requires contract instead).
```

with:

```
A recipe without FLOOR_CHECK_CMD is skipped WITH A LOG LINE — silence must
never read as coverage; every service that bundles a runtime must set one.
```

- [ ] **Step 5: Syntax- and sourcing-check (bash 3.2 rules: the recipe FLOOR_CHECK_CMD line is single-quoted, no apostrophes in it)**

```bash
/bin/bash -n scripts/floor-check-linux.sh
bash -c 'source services/storage/recipe.env && echo "$FLOOR_CHECK_CMD" | head -c 60 && echo OK'
bash -c 'source services/pgmeta/recipe.env && [ -z "${RUNTIME_REQUIRES:-}" ] && echo "no runtime_requires"'
```

Expected: exit 0, `OK`, `no runtime_requires`.

- [ ] **Step 6: Rebuild one darwin cell to confirm the manifest**

Run: `TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh pgmeta v0.96.6`
Then: `python3 -c "import json;m=json.load(open('artifacts/pgmeta/v0.96.6/darwin-arm64/manifest.json'));print(m.get('runtime_requires'))"`
Expected: `None`. (The linux floor check itself runs in CI — no linux rootfs exists locally.)

- [ ] **Step 7: Commit**

```bash
git add services/storage/recipe.env services/pgmeta/recipe.env \
        services/storage/Dockerfile.slim services/pgmeta/Dockerfile.slim \
        scripts/floor-check-linux.sh
git commit -m "storage,pgmeta: floor-check the bundled runtime; drop runtime_requires; images run the bundled node"
```

---

### Task 5: Smokes prove self-containedness

**Files:**
- Modify: `services/storage/smoke.sh:61-109`
- Modify: `services/pgmeta/smoke.sh:24-67`

**Interfaces:**
- Consumes: wrapper order from Task 3 (bundled node found without env help).
- Produces: artifact smokes that fail if the bundled runtime is missing or broken (no `SUPABASE_NODE`, sanitized `PATH`).

- [ ] **Step 1: storage smoke**

In `services/storage/smoke.sh`:

(a) Replace lines 62-67 (the shared-runtime comment + pin sourcing):

```bash
  # Host-process smoke. The artifact does not bundle Node (shared-runtime
  # contract); provide it exactly the way the CLI will, via SUPABASE_NODE,
  # pinned to the same major as the Docker runtime image (node 24).
  require_cmd python3
  # shellcheck source=scripts/nixpkgs-pin.sh
  source "$ROOT_DIR/scripts/nixpkgs-pin.sh"
```

with:

```bash
  # Host-process smoke. The artifact bundles its Node runtime; the wrapper
  # must find it with no help — SUPABASE_NODE stays unset and PATH is
  # sanitized so a host node cannot mask a broken bundle.
  require_cmd python3
```

(b) Delete lines 82-85 (the `if [[ -z "${SUPABASE_NODE:-}" ]]` resolution block) and in its place, right after the `storage_bin` executable check, add:

```bash
  [[ -x "$artifact_rootfs/node/bin/node" ]] \
    || fail "storage artifact does not bundle a node runtime: $artifact_rootfs/node/bin/node"
```

(c) In the `start_host_service storage "$storage_log" \` call, replace the pair `SUPABASE_NODE="$SUPABASE_NODE" \` with:

```bash
    SUPABASE_NODE= \
    PATH=/usr/bin:/bin \
```

- [ ] **Step 2: pgmeta smoke — same three edits**

(a) Replace lines 25-30 (comment + pin sourcing) with the same new comment (s/storage/pgmeta/) + `require_cmd python3`. (b) Delete lines 41-44 (the SUPABASE_NODE resolution) and add after the `pgmeta_bin` check:

```bash
  [[ -x "$artifact_rootfs/node/bin/node" ]] \
    || fail "pgmeta artifact does not bundle a node runtime: $artifact_rootfs/node/bin/node"
```

(c) In `start_host_service pgmeta "$pgmeta_log" \`, replace `SUPABASE_NODE="$SUPABASE_NODE" \` with the same two pairs (`SUPABASE_NODE=` and `PATH=/usr/bin:/bin`).

- [ ] **Step 3: Syntax-check**

Run: `/bin/bash -n services/storage/smoke.sh services/pgmeta/smoke.sh`
Expected: exit 0.

- [ ] **Step 4: Run both darwin artifact smokes**

Run: `TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh storage v1.62.6`
Run: `TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh pgmeta v0.96.6`
Expected: both smokes pass with the wrapper resolving the BUNDLED node (no `resolving nodejs_2x from pinned nixpkgs for the smoke runtime` line in the smoke log). If a service fails under `PATH=/usr/bin:/bin` for a reason unrelated to node resolution (a missing standard utility), report it — loosening the sanitization is an orchestrator decision, not something to quietly do.

- [ ] **Step 5: Commit**

```bash
git add services/storage/smoke.sh services/pgmeta/smoke.sh
git commit -m "storage,pgmeta: artifact smokes prove the bundled runtime (no SUPABASE_NODE, sanitized PATH)"
```

---

### Task 6: Docs — decision record + contract sentences

**Files:**
- Modify: `HOST_NATIVE_PLAN.md` (Option A decision record around lines 179-212)
- Modify: `CI_MATRIX.md` (line ~87)
- Modify: `README.md` (line ~96)

**Interfaces:** none (docs only).

- [ ] **Step 1: HOST_NATIVE_PLAN.md reversal record**

Read the Option A decision passage (`HOST_NATIVE_PLAN.md:179-212`). Do NOT rewrite history — append a dated record immediately after the Option A decision text:

```markdown
> **2026-07-09 — Decision reversed.** storage and pg-meta now bundle the
> pinned nixpkgs Node 24 runtime inside each archive (`<rootfs>/node/`, built
> by `nix/portable-node/default.nix`); the wrapper resolves `SUPABASE_NODE` →
> bundled node → PATH. Self-containedness won over disk size (~+30 MiB
> compressed per archive, accepted). `runtime_requires` is dropped from the
> manifests, both recipes carry a `FLOOR_CHECK_CMD` execution proof, and the
> Docker images derive from the bundled runtime on
> `gcr.io/distroless/base-debian13` (single node provenance). The CLI-side
> shared-runtime download is retired.
```

- [ ] **Step 2: CI_MATRIX.md and README.md contract sentences**

Run `grep -rn "shared Node runtime" README.md CI_MATRIX.md HOST_NATIVE_PLAN.md docs/` and update every live-contract occurrence (leave historical plan text alone). At `CI_MATRIX.md:87` and `README.md:96`, replace the "the Node duo resolves the shared Node runtime …" clauses with wording equivalent to:

```
the Node duo bundles its Node runtime inside the archive (wrapper prefers
node/bin/node; no external runtime, runtime_requires is null)
```

Match each file's surrounding sentence structure — these are mid-sentence clauses, not standalone lines. Also `grep -rn "runtime_requires" README.md CI_MATRIX.md` and fix any sentence that still claims the CLI enforces it for these services.

- [ ] **Step 3: Verify no stale contract text**

Run: `grep -rn "shared Node runtime" README.md CI_MATRIX.md | grep -v -i "reversed\|2026-07-09\|historical"`
Expected: no output (HOST_NATIVE_PLAN.md keeps its historical Option A text plus the reversal record).

- [ ] **Step 4: Commit**

```bash
git add HOST_NATIVE_PLAN.md CI_MATRIX.md README.md
git commit -m "docs: record the Node-bundling decision (reverses Option A shared runtime)"
```

---

### Task 7: CI validation dispatch + results tables + size measurement

This task is run by the orchestrator (needs `gh` and judgment over CI results), after the whole-branch review.

- [ ] **Step 1: Push the branch and dispatch the matrix**

```bash
git push -u origin claude/node-bundling-self-contained-de7a11
gh workflow run service-artifacts.yml --ref claude/node-bundling-self-contained-de7a11 -f services="storage pgmeta" -f force=true
```

- [ ] **Step 2: Watch the run**

`gh run list --workflow=service-artifacts.yml --branch claude/node-bundling-self-contained-de7a11` then `gh run watch <id>` (or poll). Expected green cells: storage × {linux-amd64, linux-arm64, darwin-arm64}, pgmeta × same. The known-failing "refresh results tables" job is expected to fail (org permission) — everything else must pass, INCLUDING the new floor-check steps in the linux cells.

- [ ] **Step 3: Image size measurement (design D6)**

From the CI logs (or by building the pgmeta/storage slim images from downloaded CI artifacts locally with docker), record compressed/uncompressed image sizes of the new `base-debian13 + /node` images, and compare against the previous distroless-node figures already in README's results tables. Put both numbers in the PR description.

- [ ] **Step 4: Refresh results tables locally**

Read `scripts/update-results-tables.sh` usage first; use the CI artifacts (download the built manifests) or local darwin artifacts, then run `scripts/update-results-tables.sh --merge` and commit the table changes:

```bash
git add README.md SLIM_IMAGES_REPORT.md
git commit -m "docs: refresh results tables for the node-bundled storage/pgmeta artifacts"
```

- [ ] **Step 5: Open the PR**

Base `main`, title "Bundle Node into the storage and pg-meta archives (self-contained artifacts)". Body: goal, the decision reversal pointer (HOST_NATIVE_PLAN.md record), floor/gate results from the CI run, archive + image size deltas, and the note that the handoff roadmap doc is included. End with the standard generated-with footer.
