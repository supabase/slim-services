# Host-Portability Floors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every portable archive's host requirements explicit, measured, gated in CI, and proven by execution at the floor — so archives run outside Docker on any supported host, with Docker-image tweaks derived from (never constraining) the host-native artifact.

**Architecture:** A new `scripts/os-floor.sh` computes the OS floor of a rootfs (max `GLIBC_x.y` Verneed requirement on Linux via a pure-python ELF parser; max Mach-O `minos` on macOS via `otool`). `scripts/audit-portable-artifact.sh` gains three hard gates (ELF interpreter allowlist, glibc floor ≤ policy, macOS minos ≤ policy). `scripts/ci-build-service.sh` records `target`/`libc`/`os_floor` in the manifest and runs a new execution proof: each service's `FLOOR_CHECK_CMD` (declared in `recipe.env`) inside a container whose glibc *is* the floor. Target naming reserves a `-musl` suffix; the unsuffixed `linux-<arch>` stays the glibc default.

**Tech Stack:** bash (macOS 3.2-compatible), embedded python3 (stdlib only), Docker, Nix, GitHub Actions.

## Global Constraints

- Target naming: `linux-arm64` / `linux-amd64` are the glibc targets (NO `-gnu` suffix). Future musl targets are `linux-<arch>-musl`. `darwin-arm64` unchanged; `darwin-amd64` stays out of scope.
- Linux glibc floor policy: **2.38** (measured: `beam.smp` from the shared nixpkgs pin `ac62194c` requires `GLIBC_2.38`). Supported hosts: Ubuntu 24.04+, Debian 13+, Fedora 39+. Env `SLIM_GLIBC_FLOOR_MAX` overrides globally; `GLIBC_FLOOR_MAX` in a `recipe.env` overrides per service.
- macOS floor policy: **13.0** gate default (measured: darwin `beam.smp` minos is 11.3, so ample headroom). Env `SLIM_MACOS_FLOOR_MAX` / recipe `MACOS_FLOOR_MAX` override.
- Floor-proof container: `fedora:39` (ships glibc 2.38 exactly, multi-arch). Env `SLIM_FLOOR_IMAGE` overrides.
- Every shell script must run under macOS bash 3.2 (no associative arrays, no `${var,,}`, no case-parens inside `$()` — see existing comments in `scripts/audit-portable-artifact.sh`).
- Follow repo conventions: `source "$ROOT_DIR/scripts/lib.sh"`, use `log`/`fail`/`require_cmd`, python3 heredocs for JSON manipulation.
- Local `artifacts/` trees are STALE (pre-native-first). They are structurally valid ELF/rootfs fixtures for script verification, but their measured values do not represent current CI artifacts. Expected values on stale trees are called out explicitly in each task.
- Known fixtures on this machine (fetched from cache.nixos.org, pinned nixpkgs `ac62194c`):
  - Linux ERTS: `/nix/store/r06l3qc57f6vvnxmx3d3p49f70g8mfp6-erlang-27.3.4.6` (beam.smp floor `GLIBC_2.38`)
  - Darwin ERTS: `/nix/store/xwhprhr661c34f5q0wnwlbx995hyzknp-erlang-27.3.4.6` (beam.smp minos `11.3`)

---

### Task 1: `scripts/os-floor.sh` — OS floor scanner

**Files:**
- Create: `scripts/os-floor.sh`

**Interfaces:**
- Produces (used by Tasks 2 and 3): CLI `scripts/os-floor.sh --linux|--darwin ROOTFS` printing ONE JSON object on stdout:
  - `--linux`: `{"kind": "glibc", "floor": "2.38"|null, "offender": "<rel path>"|null, "scanned": <int>, "bundled_glibc": true|false}`
  - `--darwin`: `{"kind": "macos", "floor": "11.3"|null, "offender": "<rel path>"|null, "scanned": <int>}`
  - Exit 0 on success (even when floor is null — e.g. a pure-static or non-native rootfs); exit nonzero only on usage/IO errors.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/os-floor.sh --linux ROOTFS
  scripts/os-floor.sh --darwin ROOTFS

Print the artifact's OS floor as one JSON object on stdout.

--linux reports the highest versioned glibc symbol requirement (GLIBC_x.y)
across every ELF in ROOTFS, read from the .gnu.version_r (Verneed) tables —
the exact contract the dynamic loader enforces at exec time. Files that are
themselves part of a bundled glibc (libc.so*, ld-linux*, libm.so*, ...) are
excluded from the floor: they are the bundle, not consumers of host glibc.
bundled_glibc reports whether the rootfs ships its own libc + loader pair.

--darwin reports the highest Mach-O deployment target (LC_BUILD_VERSION
minos, or legacy LC_VERSION_MIN_MACOSX version) across ROOTFS. Requires
otool, so it only runs on macOS hosts.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

mode="$1"
rootfs="$2"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"
require_cmd python3

case "$mode" in
  --linux)
    python3 - "$rootfs" <<'PY'
import json
import os
import re
import struct
import sys

rootfs = sys.argv[1]

# The glibc family we either resolve from the host (standard contract) or
# ship as a bundled pair (hermetic contract). Either way these files DEFINE
# GLIBC_* versions rather than consuming them, so they never set the floor.
GLIBC_OWN = re.compile(
    r"^(libc\.so|libc-[0-9]|ld-linux|libm\.so|libm-[0-9]|libmvec\.so|"
    r"libpthread\.so|libdl\.so|libresolv\.so|librt\.so|libutil\.so|"
    r"libnss_|libanl\.so|libthread_db\.so|libnsl\.so|libBrokenLocale\.so)"
)

SHT_GNU_VERNEED = 0x6FFFFFFE
GLIBC_RE = re.compile(r"^GLIBC_([0-9]+(?:\.[0-9]+)+)$")


def verneed_names(data):
    """Version names required by a 64-bit little-endian ELF, from Verneed."""
    if len(data) < 0x40 or data[:4] != b"\x7fELF":
        return None
    if data[4] != 2 or data[5] != 1:  # EI_CLASS != 64-bit, EI_DATA != LE
        return []
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    shnum = struct.unpack_from("<H", data, 0x3C)[0]
    if shoff == 0 or shnum == 0 or shoff + shnum * shentsize > len(data):
        return []
    sections = []
    for i in range(shnum):
        base = shoff + i * shentsize
        sh_type = struct.unpack_from("<I", data, base + 4)[0]
        sh_offset = struct.unpack_from("<Q", data, base + 0x18)[0]
        sh_size = struct.unpack_from("<Q", data, base + 0x20)[0]
        sh_link = struct.unpack_from("<I", data, base + 0x28)[0]
        sections.append((sh_type, sh_offset, sh_size, sh_link))
    names = []
    for sh_type, off, size, link in sections:
        if sh_type != SHT_GNU_VERNEED or link >= len(sections):
            continue
        str_off = sections[link][1]
        pos = off
        end = off + size
        while pos + 16 <= end:
            vn_cnt = struct.unpack_from("<H", data, pos + 2)[0]
            vn_aux = struct.unpack_from("<I", data, pos + 8)[0]
            vn_next = struct.unpack_from("<I", data, pos + 12)[0]
            apos = pos + vn_aux
            for _ in range(vn_cnt):
                if apos + 16 > len(data):
                    break
                vna_name = struct.unpack_from("<I", data, apos + 8)[0]
                vna_next = struct.unpack_from("<I", data, apos + 12)[0]
                nstart = str_off + vna_name
                nend = data.find(b"\x00", nstart)
                if 0 <= nstart < nend:
                    names.append(data[nstart:nend].decode("ascii", "replace"))
                if vna_next == 0:
                    break
                apos += vna_next
            if vn_next == 0:
                break
            pos += vn_next
    return names


def vkey(v):
    return tuple(int(x) for x in v.split("."))


floor = None
offender = None
scanned = 0
saw_libc = False
saw_loader = False

for dirpath, _dirs, files in os.walk(rootfs):
    for fname in files:
        path = os.path.join(dirpath, fname)
        try:
            with open(path, "rb") as fh:
                head = fh.read(4)
                if head != b"\x7fELF":
                    continue
                data = head + fh.read()
        except OSError:
            continue
        scanned += 1
        if fname.startswith("libc.so"):
            saw_libc = True
        if fname.startswith("ld-linux"):
            saw_loader = True
        if GLIBC_OWN.match(fname):
            continue
        names = verneed_names(data)
        if not names:
            continue
        for name in names:
            m = GLIBC_RE.match(name)
            if not m:
                continue
            v = m.group(1)
            if floor is None or vkey(v) > vkey(floor):
                floor = v
                offender = os.path.relpath(path, rootfs)

print(json.dumps({
    "kind": "glibc",
    "floor": floor,
    "offender": offender,
    "scanned": scanned,
    "bundled_glibc": bool(saw_libc and saw_loader),
}))
PY
    ;;
  --darwin)
    require_cmd otool
    python3 - "$rootfs" <<'PY'
import json
import os
import re
import subprocess
import sys

rootfs = sys.argv[1]

MACHO_MAGICS = (
    b"\xcf\xfa\xed\xfe",  # MH_MAGIC_64 (LE on disk)
    b"\xce\xfa\xed\xfe",  # MH_MAGIC (32-bit)
    b"\xca\xfe\xba\xbe",  # FAT_MAGIC (BE on disk)
    b"\xbe\xba\xfe\xca",  # FAT_CIGAM
)

MINOS_RE = re.compile(r"^\s*(?:minos|version)\s+([0-9]+(?:\.[0-9]+)+)\s*$")


def vkey(v):
    return tuple(int(x) for x in v.split("."))


floor = None
offender = None
scanned = 0

for dirpath, _dirs, files in os.walk(rootfs):
    for fname in files:
        path = os.path.join(dirpath, fname)
        try:
            with open(path, "rb") as fh:
                if fh.read(4) not in MACHO_MAGICS:
                    continue
        except OSError:
            continue
        scanned += 1
        try:
            out = subprocess.run(
                ["otool", "-l", path],
                capture_output=True, text=True, timeout=60,
            ).stdout
        except (subprocess.SubprocessError, OSError):
            continue
        in_build = False
        platform_macos = False
        for line in out.splitlines():
            stripped = line.strip()
            if stripped.startswith("cmd "):
                cmd = stripped.split()[-1]
                in_build = cmd in ("LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX")
                platform_macos = cmd == "LC_VERSION_MIN_MACOSX"
                continue
            if not in_build:
                continue
            if stripped.startswith("platform"):
                platform_macos = stripped.split()[-1] in ("MACOS", "1")
                continue
            m = MINOS_RE.match(line)
            if m and platform_macos:
                v = m.group(1)
                if floor is None or vkey(v) > vkey(floor):
                    floor = v
                    offender = os.path.relpath(path, rootfs)
                in_build = False

print(json.dumps({
    "kind": "macos",
    "floor": floor,
    "offender": offender,
    "scanned": scanned,
}))
PY
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
```

- [ ] **Step 2: Make it executable and verify usage/error paths**

Run: `chmod +x scripts/os-floor.sh && scripts/os-floor.sh --help && scripts/os-floor.sh --linux /nonexistent; echo "exit=$?"`
Expected: usage text printed, then `[slim] ERROR: rootfs directory not found: /nonexistent`, `exit=1`.

- [ ] **Step 3: Verify --linux against the pinned Linux ERTS fixture**

Run: `scripts/os-floor.sh --linux /nix/store/r06l3qc5*-erlang-27.3.4.6 | python3 -m json.tool`
Expected: `"kind": "glibc"`, `"floor": "2.38"`, offender under `lib/erlang/` (e.g. an ERTS binary or `epmd`), `"bundled_glibc": false`.

- [ ] **Step 4: Verify --linux against the stale local rootfs trees**

Run: `for s in realtime pooler auth postgrest; do printf '%s: ' "$s"; scripts/os-floor.sh --linux artifacts/$s/*/linux-arm64/rootfs; done`
Expected (stale-tree values, structural correctness only):
- `realtime`: floor `2.34`, `bundled_glibc: false`
- `pooler`: floor `2.30`, `bundled_glibc: false`
- `auth`: floor `null` (static Go), `scanned` ≥ 1
- `postgrest`: floor `2.38`, `bundled_glibc: true` (upstream-image extract bundles Ubuntu libc + loader)

- [ ] **Step 5: Verify --darwin against the pinned darwin ERTS fixture**

Run: `scripts/os-floor.sh --darwin /nix/store/xwhprhr6*-erlang-27.3.4.6 | python3 -m json.tool`
Expected: `"kind": "macos"`, `"floor": "11.3"`, offender a `beam.smp`/ERTS binary, `scanned` > 10.

- [ ] **Step 6: Commit**

```bash
git add scripts/os-floor.sh
git commit -m "scripts: add os-floor.sh, the artifact OS-floor scanner (glibc Verneed / Mach-O minos)"
```

---

### Task 2: Floor and interpreter gates in the portable audit

**Files:**
- Modify: `scripts/audit-portable-artifact.sh` (extend both `--linux` and `--darwin` branches; usage text)

**Interfaces:**
- Consumes: `scripts/os-floor.sh --linux|--darwin ROOTFS` JSON (Task 1).
- Produces: audit fails when (a) any ELF requests a non-standard program interpreter, (b) glibc floor exceeds `${GLIBC_FLOOR_MAX:-${SLIM_GLIBC_FLOOR_MAX:-2.38}}` (skipped with a log line when `bundled_glibc` is true), (c) macOS floor exceeds `${MACOS_FLOOR_MAX:-${SLIM_MACOS_FLOOR_MAX:-13.0}}`. Callers (Task 3) may export `GLIBC_FLOOR_MAX`/`MACOS_FLOOR_MAX` from a recipe before invoking.

- [ ] **Step 1: Add the interpreter allowlist check to the `--linux` branch**

Insert after the existing `unresolved` check (after the `fail "Linux artifact has unresolved shared-library dependencies"` block, still inside the `--linux)` case):

```bash
    # Every ELF must request the standard system loader for the target arch.
    # Anything else — a /nix/store loader (build-machine leak, resolves only
    # where that store exists) or a musl loader on a glibc target — breaks
    # the moment the archive lands on a clean host. (Real leak class seen:
    # a bundled Nix store subtree whose ELFs kept their store interpreters.)
    case "$(uname -m)" in
      aarch64|arm64) allowed_interp="/lib/ld-linux-aarch64.so.1" ;;
      x86_64|amd64) allowed_interp="/lib64/ld-linux-x86-64.so.2" ;;
      *) fail "unsupported audit architecture: $(uname -m)" ;;
    esac
    bad_interps="$(
      find "$rootfs" -type f 2>/dev/null \
        | while IFS= read -r file_path; do
            if file "$file_path" | grep -q 'ELF'; then
              readelf -l "$file_path" 2>/dev/null \
                | awk -v file="$file_path" -v ok="$allowed_interp" '
                    /Requesting program interpreter/ {
                      line = $0
                      sub(/^.*\[/, "", line)
                      sub(/\].*$/, "", line)
                      if (line != ok) print file " -> " line
                    }'
            fi
          done
    )"
    if [[ -n "$bad_interps" ]]; then
      printf '%s\n' "$bad_interps" >&2
      fail "Linux artifact contains ELFs with non-standard program interpreters (expected $allowed_interp)"
    fi
```

- [ ] **Step 2: Add the glibc floor gate to the `--linux` branch (after Step 1's block)**

```bash
    # Host floor gate: the highest GLIBC_x.y requirement any shipped ELF
    # places on the host must stay within the supported-host policy
    # (CI_MATRIX.md). Artifacts that bundle their own libc + loader pair are
    # a different (hermetic) contract and are proven by the floor-container
    # execution check instead.
    floor_json="$("$ROOT_DIR/scripts/os-floor.sh" --linux "$rootfs")"
    log "linux floor: $floor_json"
    glibc_floor_max="${GLIBC_FLOOR_MAX:-${SLIM_GLIBC_FLOOR_MAX:-2.38}}"
    python3 - "$floor_json" "$glibc_floor_max" <<'PY' || fail "Linux artifact exceeds the glibc floor policy"
import json
import sys

info = json.loads(sys.argv[1])
limit = tuple(int(x) for x in sys.argv[2].split("."))
if info.get("bundled_glibc"):
    print(f"[slim] glibc floor gate skipped: artifact bundles its own glibc"
          f" (measured floor {info.get('floor')})")
    raise SystemExit(0)
floor = info.get("floor")
if floor is None:
    raise SystemExit(0)
if tuple(int(x) for x in floor.split(".")) > limit:
    print(f"[slim] ERROR: glibc floor {floor} exceeds policy {sys.argv[2]}"
          f" (offender: {info.get('offender')})", file=sys.stderr)
    raise SystemExit(1)
PY
```

- [ ] **Step 3: Add the macOS floor gate to the `--darwin` branch**

Insert after the existing `fail "Darwin artifact contains absolute Nix store references"` block, still inside the `--darwin)` case:

```bash
    # Host floor gate: highest Mach-O deployment target shipped must stay
    # within the supported macOS policy (CI_MATRIX.md).
    floor_json="$("$ROOT_DIR/scripts/os-floor.sh" --darwin "$rootfs")"
    log "darwin floor: $floor_json"
    macos_floor_max="${MACOS_FLOOR_MAX:-${SLIM_MACOS_FLOOR_MAX:-13.0}}"
    python3 - "$floor_json" "$macos_floor_max" <<'PY' || fail "Darwin artifact exceeds the macOS floor policy"
import json
import sys

info = json.loads(sys.argv[1])
limit = tuple(int(x) for x in sys.argv[2].split("."))
floor = info.get("floor")
if floor is None:
    raise SystemExit(0)
if tuple(int(x) for x in floor.split(".")) > limit:
    print(f"[slim] ERROR: macOS floor {floor} exceeds policy {sys.argv[2]}"
          f" (offender: {info.get('offender')})", file=sys.stderr)
    raise SystemExit(1)
PY
```

Also add `require_cmd python3` next to the existing `require_cmd` lines in both branches, and mention the gates in the script's usage heredoc:

```text
Fail if a portable artifact still has unresolved or host-specific runtime
deps, ships an ELF with a non-standard program interpreter, or exceeds the
OS floor policy (glibc 2.38 on Linux, macOS 13.0 on darwin; override with
GLIBC_FLOOR_MAX / MACOS_FLOOR_MAX or SLIM_GLIBC_FLOOR_MAX /
SLIM_MACOS_FLOOR_MAX).
```

- [ ] **Step 4: Verify the floor gate logic without readelf (portable-logic check)**

The `--linux` audit path requires linux tooling (`ldd`, `readelf`) so the full audit can only run on a linux host/CI. Verify the gate's python logic standalone on this machine:

Run:
```bash
python3 - '{"kind":"glibc","floor":"2.39","offender":"bin/x","scanned":3,"bundled_glibc":false}' 2.38 <<'PY'
import json, sys
info = json.loads(sys.argv[1])
limit = tuple(int(x) for x in sys.argv[2].split("."))
floor = info.get("floor")
raise SystemExit(1 if floor and tuple(int(x) for x in floor.split(".")) > limit else 0)
PY
echo "exit=$?"
```
Expected: `exit=1` (2.39 > 2.38 rejected). Re-run with floor `"2.38"`: expected `exit=0`.

- [ ] **Step 5: Verify the --darwin gate end-to-end on the darwin ERTS fixture**

Run: `bash scripts/audit-portable-artifact.sh --darwin /nix/store/xwhprhr6*-erlang-27.3.4.6; echo "exit=$?"`
Expected: FAILS (`exit=1`) — but on the *store-path* fixture the failure is the pre-existing "absolute Nix store references" check, which fires before the floor gate. To exercise the floor gate itself: `SLIM_MACOS_FLOOR_MAX=11.0` with a minimal copy:

```bash
tmp="$(mktemp -d)" && mkdir -p "$tmp/bin" && cp /nix/store/xwhprhr6*-erlang-27.3.4.6/lib/erlang/erts-*/bin/beam.smp "$tmp/bin/"
SLIM_MACOS_FLOOR_MAX=11.0 bash scripts/audit-portable-artifact.sh --darwin "$tmp/bin" >/dev/null 2>&1; echo "gate-reject=$?"
SLIM_MACOS_FLOOR_MAX=13.0 bash scripts/audit-portable-artifact.sh --darwin "$tmp/bin"; echo "gate-pass=$?"
rm -rf "$tmp"
```
Expected: `gate-reject=1` (11.3 > 11.0), `gate-pass=0` (beam.smp alone has a valid signature and no store refs, so only the floor gate decides).

- [ ] **Step 6: Commit**

```bash
git add scripts/audit-portable-artifact.sh
git commit -m "audit: gate portable artifacts on ELF interpreter, glibc floor, and macOS minos"
```

---

### Task 3: Record `target`, `libc`, and `os_floor` in the manifest

**Files:**
- Modify: `scripts/build-artifact-from-source.sh:199-233` (manifest dict)
- Modify: `scripts/build-artifact-from-nix.sh:294-340` (manifest dict)
- Modify: `scripts/build-artifact-from-image.sh` (manifest dict — same two keys; find the analogous `manifest = {` python block)
- Modify: `scripts/ci-build-service.sh` (load recipe, export floor overrides, merge `os_floor`)

**Interfaces:**
- Consumes: `scripts/os-floor.sh` JSON (Task 1); audit env contract (Task 2).
- Produces: every `manifest.json` gains `"target"` (e.g. `"linux-arm64"`, matching the artifact dir name) and, for linux targets, `"libc": "glibc"`. Portable artifacts built on a matching host additionally gain `"os_floor": {...}` (the os-floor.sh JSON). Task 4 and the CLI consume these.

- [ ] **Step 1: Add `target`/`libc` to all three manifest writers**

In each manifest python dict, immediately after the `"arch"` entry, add:

```python
    "target": "$(artifact_platform_dir "$TARGET_OS" "$ARCH")",
    "libc": "glibc" if "$TARGET_OS" == "linux" else None,
```

(The `$(...)` is bash command substitution inside the existing heredoc — both scripts already interpolate shell into the python source this way. `build-artifact-from-image.sh` may name its OS/arch variables differently; mirror whatever the surrounding dict uses.)

- [ ] **Step 2: Load the recipe and export floor overrides in `ci-build-service.sh`**

After `log "CI target: service=$service version=$version target=$TARGET_OS/$ARCH"` add:

```bash
# Recipe-level policy knobs for the audit and the floor check below
# (GLIBC_FLOOR_MAX, MACOS_FLOOR_MAX, FLOOR_CHECK_CMD are plain recipe vars).
load_recipe "$service"
export GLIBC_FLOOR_MAX="${GLIBC_FLOOR_MAX:-}"
export MACOS_FLOOR_MAX="${MACOS_FLOOR_MAX:-}"
```

Note: `export VAR=""` would defeat the audit's `${GLIBC_FLOOR_MAX:-...}` default — it would not, because `:-` treats empty as unset. Keep the pattern exactly as above so unset recipe vars fall through to the `SLIM_*`/hardcoded defaults.

- [ ] **Step 3: Merge `os_floor` into the manifest in `ci-build-service.sh`**

Immediately after the existing portable-audit block (`"$ROOT_DIR/scripts/audit-portable-artifact.sh" "$audit_mode" "$rootfs"` and its closing `fi`), add:

```bash
# Record the measured OS floor in the manifest so distribution consumers
# (the CLI) can pre-flight host compatibility with a clear error instead of
# a loader crash.
if [[ "$artifact_portable" == "true" && "$TARGET_OS" == "$(host_os)" ]]; then
  floor_mode="--linux"
  [[ "$TARGET_OS" == "darwin" ]] && floor_mode="--darwin"
  os_floor_json="$("$ROOT_DIR/scripts/os-floor.sh" "$floor_mode" "$rootfs")"
  log "recording os floor in manifest: $os_floor_json"
  python3 - "$manifest" "$os_floor_json" <<'PY'
import json
import sys

manifest_path, floor_raw = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
data["os_floor"] = json.loads(floor_raw)
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
fi
```

- [ ] **Step 4: Verify the manifest wiring shape without a build**

Run:
```bash
tmp="$(mktemp -d)" && printf '{"arch":"arm64"}\n' > "$tmp/manifest.json"
python3 - "$tmp/manifest.json" '{"kind":"glibc","floor":"2.38","offender":"bin/x","scanned":1,"bundled_glibc":false}' <<'PY'
import json, sys
with open(sys.argv[1]) as fh: data = json.load(fh)
data["os_floor"] = json.loads(sys.argv[2])
print(json.dumps(data))
PY
rm -rf "$tmp"
```
Expected: JSON echoing both keys. Then `bash -n scripts/ci-build-service.sh scripts/build-artifact-from-source.sh scripts/build-artifact-from-nix.sh scripts/build-artifact-from-image.sh` — expected: no output (parse-clean).

- [ ] **Step 5: Commit**

```bash
git add scripts/build-artifact-from-source.sh scripts/build-artifact-from-nix.sh scripts/build-artifact-from-image.sh scripts/ci-build-service.sh
git commit -m "manifests: record target, libc, and measured os_floor"
```

---

### Task 4: Floor-container execution proof

**Files:**
- Create: `scripts/floor-check-linux.sh`
- Modify: `services/realtime/recipe.env`, `services/pooler/recipe.env`, `services/analytics/recipe.env`, `services/auth/recipe.env`, `services/postgrest/recipe.env`, `services/edge-runtime/recipe.env`, `services/postgres/recipe.env` (add `FLOOR_CHECK_CMD`)
- Modify: `services/storage/recipe.env`, `services/pgmeta/recipe.env` (comment documenting the deliberate skip)
- Modify: `scripts/ci-build-service.sh` (invoke the check on linux targets)

**Interfaces:**
- Consumes: recipe var `FLOOR_CHECK_CMD` — a bash command string executed inside the floor container with `$ROOTFS` set to the mounted artifact rootfs.
- Produces: `scripts/floor-check-linux.sh SERVICE ROOTFS` — exit 0 when the command succeeds in `${SLIM_FLOOR_IMAGE:-fedora:39}` or when the recipe declares no command (logged as skipped); nonzero otherwise.

- [ ] **Step 1: Write `scripts/floor-check-linux.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/floor-check-linux.sh SERVICE ROOTFS

Execution proof at the supported glibc floor: run the service's
FLOOR_CHECK_CMD (from services/SERVICE/recipe.env) inside a container whose
glibc IS the floor (default fedora:39 = glibc 2.38; override with
SLIM_FLOOR_IMAGE). The command sees the artifact at $ROOTFS (read-only) and
must exercise the main binary far enough to prove the dynamic loader
resolves everything: exec + link + NIF/dlopen load. No network is available.

A recipe without FLOOR_CHECK_CMD is skipped WITH A LOG LINE — silence must
never read as coverage (Node-runtime services are checked by the CLI's
runtime_requires contract instead).
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

service="$1"
rootfs="$2"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"

load_recipe "$service"

if [[ -z "${FLOOR_CHECK_CMD:-}" ]]; then
  log "floor check SKIPPED for $service: no FLOOR_CHECK_CMD in recipe (not covered at the glibc floor)"
  exit 0
fi

require_cmd docker
floor_image="${SLIM_FLOOR_IMAGE:-fedora:39}"
rootfs_abs="$(cd "$rootfs" && pwd)"

log "floor check: $service in $floor_image"
if ! docker run --rm --network none \
  -v "$rootfs_abs":/rootfs:ro \
  -e ROOTFS=/rootfs \
  -e HOME=/tmp \
  -e RELEASE_TMP=/tmp \
  "$floor_image" /bin/bash -c "set -euo pipefail; $FLOOR_CHECK_CMD"; then
  fail "floor check failed for $service in $floor_image (glibc floor violation or launcher regression)"
fi
log "floor check passed: $service runs at the glibc floor ($floor_image)"
```

- [ ] **Step 2: Add `FLOOR_CHECK_CMD` to the recipes**

Each command must load the main binary and its dynamic closure. The BEAM
releases use `eval` with dummy env (config providers read env at eval; no DB
connection is made) and force the crypto NIF (openssl dylib) to load.

`services/realtime/recipe.env` (env mirrors the artifact smoke in `services/realtime/smoke.sh`):

```bash
# Execution proof at the glibc floor (scripts/floor-check-linux.sh): boot the
# release VM via eval with dummy config env and force the crypto NIF to load.
FLOOR_CHECK_CMD='env DB_HOST=127.0.0.1 DB_PORT=5432 DB_USER=postgres DB_PASSWORD=floor DB_NAME=floor DB_ENC_KEY=0123456789abcdef API_JWT_SECRET=floor-check-api-secret-at-least-32ch METRICS_JWT_SECRET=floor-check-metrics-secret-32chars SECRET_KEY_BASE=floorcheckfloorcheckfloorcheckfloorcheckfloorcheckfloorcheck1234 APP_NAME=floor PORT=4000 "$ROOTFS/bin/realtime" eval "IO.puts(byte_size(:crypto.hash(:sha256, \"floor\")))"'
```

`services/pooler/recipe.env` (env mirrors `services/pooler/smoke.sh`):

```bash
FLOOR_CHECK_CMD='env DATABASE_URL=ecto://postgres:floor@127.0.0.1:5432/floor SECRET_KEY_BASE=floorcheckfloorcheckfloorcheckfloorcheckfloorcheckfloorcheck1234 API_JWT_SECRET=floor-check-api-secret-at-least-32ch METRICS_JWT_SECRET=floor-check-metrics-secret-32chars PORT=4000 "$ROOTFS/bin/supavisor" eval "IO.puts(byte_size(:crypto.hash(:sha256, \"floor\")))"'
```

`services/analytics/recipe.env` (env mirrors `services/analytics/smoke.sh`; the base64 value is `0123456789abcdef0123456789abcdef` encoded):

```bash
FLOOR_CHECK_CMD='env DB_DATABASE=floor DB_HOSTNAME=127.0.0.1 DB_PORT=5432 DB_USERNAME=postgres DB_PASSWORD=floor LOGFLARE_SINGLE_TENANT=true LOGFLARE_API_KEY=floor-check LOGFLARE_DB_ENCRYPTION_KEY=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY= PHX_HTTP_PORT=4000 PHX_SECRET_KEY_BASE=floorcheckfloorcheckfloorcheckfloorcheckfloorcheckfloorcheck1234 "$ROOTFS/bin/logflare" eval "IO.puts(byte_size(:crypto.hash(:sha256, \"floor\")))"'
```

`services/auth/recipe.env` (static Go binary; `-h` is cobra's zero-exit help):

```bash
FLOOR_CHECK_CMD='"$ROOTFS/usr/local/bin/auth" -h >/dev/null && echo floor-ok'
```

`services/postgrest/recipe.env` (`--example` prints example config, exit 0):

```bash
FLOOR_CHECK_CMD='"$ROOTFS/bin/postgrest" --example >/dev/null && echo floor-ok'
```

`services/edge-runtime/recipe.env` (the bin/edge-runtime wrapper sets LD_LIBRARY_PATH):

```bash
FLOOR_CHECK_CMD='"$ROOTFS/bin/edge-runtime" --help >/dev/null && echo floor-ok'
```

`services/postgres/recipe.env` (wrapper scripts are bash; fedora has bash):

```bash
FLOOR_CHECK_CMD='"$ROOTFS/bin/postgres" --version && "$ROOTFS/bin/initdb" --version'
```

If a launcher path differs in the CURRENT artifact layout (only postgres is
uncertain — its rootfs is the upstream flake's `psql_17_cli_portable`
output), adjust the path to the real one found in the built rootfs; the
executor must confirm against a freshly built artifact, not the stale local
tree.

`services/storage/recipe.env` and `services/pgmeta/recipe.env` — add a comment only:

```bash
# No FLOOR_CHECK_CMD: the artifact is a JS bundle with no bundled runtime;
# host compatibility is the shared Node runtime's contract
# (runtime_requires in the manifest), which the CLI enforces.
```

- [ ] **Step 3: Wire the check into `ci-build-service.sh`**

Immediately after the `os_floor` merge block from Task 3, add:

```bash
# Execution proof at the glibc floor: run the recipe's FLOOR_CHECK_CMD in a
# container whose glibc IS the floor. Linux-only (needs Docker) and only
# where the host matches the target (native rootfs).
if [[ "$artifact_portable" == "true" && "$TARGET_OS" == "linux" && "$(host_os)" == "linux" ]]; then
  "$ROOT_DIR/scripts/floor-check-linux.sh" "$service" "$rootfs"
fi
```

- [ ] **Step 4: Verify skip path and parse-cleanliness locally**

Run: `chmod +x scripts/floor-check-linux.sh && bash -n scripts/floor-check-linux.sh && scripts/floor-check-linux.sh storage artifacts/storage/*/linux-arm64/rootfs; echo "exit=$?"`
Expected: `floor check SKIPPED for storage: no FLOOR_CHECK_CMD in recipe ...`, `exit=0`.

Run: `for s in realtime pooler analytics auth postgrest edge-runtime postgres; do TARGET_OS=linux bash -c 'source scripts/lib.sh; load_recipe '"$s"'; [[ -n "${FLOOR_CHECK_CMD:-}" ]] && echo "'"$s"': ok"'; done`
Expected: seven `<service>: ok` lines (recipes parse and define the command).

(The docker execution path can only be verified on a linux host — it runs in CI in Task 7. If Docker Desktop is running locally, an optional spot check: `scripts/floor-check-linux.sh postgrest artifacts/postgrest/v14.14/linux-arm64/rootfs` — on the STALE postgrest tree this may legitimately fail because of its bundled Ubuntu libc 2.43 vs the fedora:39 loader; treat any outcome as informational.)

- [ ] **Step 5: Commit**

```bash
git add scripts/floor-check-linux.sh scripts/ci-build-service.sh services/*/recipe.env
git commit -m "CI: prove every portable linux artifact executes at the glibc floor (fedora:39)"
```

---

### Task 5: Target-naming reservation (`-musl`) and docs

**Files:**
- Modify: `scripts/lib.sh:101-105` (`artifact_platform_dir`)
- Modify: `scripts/ci-build-service.sh` (guard)
- Modify: `CI_MATRIX.md`, `HOST_NATIVE_PLAN.md`, `NIX_PORTABLE_ARTIFACT_PLAYBOOK.md`, `README.md`

**Interfaces:**
- Produces: `TARGET_LIBC=musl` yields `linux-<arch>-musl` artifact dirs/archive names everywhere `artifact_platform_dir` is used; unset/`glibc` keeps today's `linux-<arch>`. Builds with non-glibc libc fail fast until implemented.

- [ ] **Step 1: Extend `artifact_platform_dir` in `scripts/lib.sh`**

Replace the existing function with:

```bash
# linux-<arch> is the glibc target (the default, no suffix). Alternative
# libc flavors get a suffix: TARGET_LIBC=musl -> linux-<arch>-musl
# (reserved for future Alpine targets; no builds produce it yet).
artifact_platform_dir() {
  local os arch libc
  os="$(normalize_os "$1")"
  arch="$(normalize_arch "$2")"
  libc="${TARGET_LIBC:-glibc}"
  if [[ "$os" == "linux" && "$libc" != "glibc" ]]; then
    printf '%s-%s-%s' "$os" "$arch" "$libc"
  else
    printf '%s-%s' "$os" "$arch"
  fi
}
```

- [ ] **Step 2: Fail fast on unimplemented libc targets in `ci-build-service.sh`**

After the Task 3 `load_recipe` block, add:

```bash
if [[ "$TARGET_OS" == "linux" && "${TARGET_LIBC:-glibc}" != "glibc" ]]; then
  fail "TARGET_LIBC=${TARGET_LIBC} is a reserved target flavor; no musl builds are implemented yet"
fi
```

- [ ] **Step 3: Verify**

Run: `bash -c 'source scripts/lib.sh; artifact_platform_dir linux arm64; echo; TARGET_LIBC=musl artifact_platform_dir linux arm64; echo; TARGET_LIBC=musl artifact_platform_dir darwin arm64; echo'`
Expected output lines: `linux-arm64`, `linux-arm64-musl`, `darwin-arm64`.

Run: `TARGET_OS=linux ARCH=arm64 TARGET_LIBC=musl scripts/ci-build-service.sh auth v2.192.0; echo "exit=$?"`
Expected: fails immediately with the reserved-flavor message, `exit=1`.

- [ ] **Step 4: Document the contract**

- `CI_MATRIX.md` — in the Matrix section after the archive-outputs code block, add:

```markdown
`linux-<arch>` archives are glibc artifacts. The libc flavor is part of the
target name only when it is not glibc: future Alpine targets will publish
`linux-<arch>-musl` archives (`TARGET_LIBC=musl`, reserved — no musl builds
exist yet). There is deliberately no `-gnu` suffix.

## Host Floor Policy

Portable linux archives may require at most **glibc 2.38** from the host
(`GLIBC_2.x` Verneed max across all shipped ELFs; measured and gated by
`scripts/audit-portable-artifact.sh`, recorded as `os_floor` in the
manifest). Supported hosts: Ubuntu 24.04+, Debian 13+, Fedora 39+ (any
distro with glibc >= 2.38). Every linux artifact is additionally executed
inside `fedora:39` (glibc 2.38 exactly) by `scripts/floor-check-linux.sh`.
Darwin archives may require at most **macOS 13.0** (Mach-O minos, same
audit). Per-service overrides: `GLIBC_FLOOR_MAX` / `MACOS_FLOOR_MAX` in
`recipe.env`; global: `SLIM_GLIBC_FLOOR_MAX` / `SLIM_MACOS_FLOOR_MAX`.
```

- `NIX_PORTABLE_ARTIFACT_PLAYBOOK.md` — in "Linux Dynamic Linking" after the "glibc-based Linux ARM64 artifact" paragraph, add:

```markdown
That contract now has a number: shipped ELFs may reference at most
`GLIBC_2.38` (the floor of the shared nixpkgs pin's toolchain output — e.g.
ERTS `beam.smp` requires exactly 2.38). `scripts/os-floor.sh --linux`
measures it, the portable audit gates it, and
`scripts/floor-check-linux.sh` proves it by executing the launcher inside
fedora:39. Raising the shared pin can raise this floor silently — the gate
exists to catch exactly that.
```

- `HOST_NATIVE_PLAN.md` — append a dated section:

```markdown
## Host Floor Contract (2026-07)

Decision: archives must be as portable as possible out of the box — no
CLI-side relocation/patching. Since an ELF interpreter path is absolute and
baked at link time, "one artifact for every Linux" is impossible; instead
the libc contract is part of the target name (`linux-<arch>` = glibc,
`linux-<arch>-musl` reserved) and the glibc contract carries an explicit,
measured, CI-gated floor: glibc 2.38 (Ubuntu 24.04+/Debian 13+/Fedora 39+),
macOS 13.0 on darwin (measured ERTS minos: 11.3). Enforced by
scripts/os-floor.sh + audit gates + a fedora:39 execution proof
(scripts/floor-check-linux.sh); recorded as `target`, `libc`, `os_floor`
in every manifest so the CLI can pre-flight hosts with a clear error.
NixOS is served by the Nix packages themselves, not archives. Lowering the
floor below 2.38 (Ubuntu 22.04/RHEL 9) would require linking against an
older glibc (old-stdenv rebuilds of OTP/deps) — deferred until demand.
```

- `README.md` — in the section describing host-native archives (around the `runtime_requires` mention at line ~97), add one sentence:

```markdown
Linux archives are glibc artifacts with a measured, CI-gated host floor
(glibc >= 2.38: Ubuntu 24.04+, Debian 13+, Fedora 39+ — see CI_MATRIX.md);
macOS archives require macOS 13+. The manifest records the exact floor as
`os_floor`.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh scripts/ci-build-service.sh CI_MATRIX.md HOST_NATIVE_PLAN.md NIX_PORTABLE_ARTIFACT_PLAYBOOK.md README.md
git commit -m "targets: reserve -musl flavor naming and document the host floor contract"
```

---

### Task 6: Local validation sweep

**Files:** none created — runs the new tooling against everything available on this machine.

- [ ] **Step 1: Syntax-check every touched script**

Run: `bash -n scripts/os-floor.sh scripts/floor-check-linux.sh scripts/audit-portable-artifact.sh scripts/ci-build-service.sh scripts/lib.sh scripts/build-artifact-from-source.sh scripts/build-artifact-from-nix.sh scripts/build-artifact-from-image.sh`
Expected: no output. If `shellcheck` is installed, also run it on the two new scripts and fix warnings (respect existing repo suppressions style).

- [ ] **Step 2: Floor scanner sweep over all stale local linux artifacts**

Run: `for d in artifacts/*/*/linux-arm64/rootfs; do printf '%s ' "$d"; scripts/os-floor.sh --linux "$d"; done`
Expected: one JSON per service, no crashes, values consistent with Task 1 Step 4 (plus: `analytics` 2.38, `edge-runtime` 2.35, `storage`/`pgmeta` ≤ 2.25, `postgres` reports `bundled_glibc: true`).

- [ ] **Step 3: Confirm the recipes still parse for both targets**

Run: `for s in edge-runtime studio pooler analytics storage postgrest realtime pgmeta auth postgres; do for os in linux darwin; do TARGET_OS=$os bash -c 'source scripts/lib.sh; load_recipe '"$s"' >/dev/null 2>&1 && echo "'"$s"'/'"$os"': ok" || echo "'"$s"'/'"$os"': FAIL"'; done; done`
Expected: 20 `ok` lines.

- [ ] **Step 4: Commit any fixes, then push the branch**

```bash
git push -u origin claude/non-self-contained-services-170470
```

---

### Task 7: CI measurement run and floor report

**Files:** none in-repo (workflow dispatch + analysis). Requires `gh` auth.

The fingerprint in `service-artifacts.yml` includes `scripts/`, so every service rebuilds — the run measures CURRENT artifacts under the new gates.

- [ ] **Step 1: Dispatch the full matrix on this branch**

```bash
gh workflow run service-artifacts.yml --ref claude/non-self-contained-services-170470
gh run watch "$(gh run list --workflow=service-artifacts.yml --branch claude/non-self-contained-services-170470 --limit 1 --json databaseId --jq '.[0].databaseId')" --interval 60
```
Expected duration: up to ~2h (timeout 240m per job). Also dispatch `edge-runtime-artifacts.yml` the same way if it consumes `ci-build-service.sh` (confirm by reading the workflow; if it has its own build steps, add the audit/floor steps there in a follow-up commit mirroring `service-artifacts.yml`).

- [ ] **Step 2: Collect manifests and build the floor report**

```bash
run_id="$(gh run list --workflow=service-artifacts.yml --branch claude/non-self-contained-services-170470 --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run download "$run_id" -D /tmp/floor-manifests
python3 - <<'PY'
import glob, json
for p in sorted(glob.glob("/tmp/floor-manifests/*/manifest.json")):
    m = json.load(open(p))
    print(f"{m['service']:12s} {m.get('target','?'):14s} floor={m.get('os_floor',{}).get('floor')} "
          f"bundled_glibc={m.get('os_floor',{}).get('bundled_glibc')}")
PY
```
Expected: every green cell shows a floor ≤ 2.38 (linux) / ≤ 13.0 (darwin).

- [ ] **Step 3: Triage failures by decision rule**

For each red cell, classify:
1. **Interp violation** (audit lists non-standard interpreters) → Task 8 (expected for postgres if its rootfs still carries a bundled Nix store subtree with unpatched ELFs — the stale local tree does).
2. **glibc floor > 2.38** → find the offender in the audit log. If it is a bundled utility (coreutils-class), swap its source to the shared 25.05 pin or busybox in the service's nix package. If it is the service's own binary, do NOT chase an old-glibc rebuild now: set `GLIBC_FLOOR_MAX=<measured>` in the recipe with a dated comment and a follow-up note in `HOST_NATIVE_PLAN.md`, and raise the documented supported-host list for that service.
3. **Floor-check execution failure** in fedora:39 with a working audit → launcher bug (wrong path in `FLOOR_CHECK_CMD`, missing env var for config eval) → fix the recipe command using the container's stderr, which the script surfaces.
4. **postgrest bundled-libc mismatch** (bundled Ubuntu libc 2.43 + host loader 2.38 crashing in the floor container) → prune the bundled glibc-family files from the linux artifact (its `Dockerfile.artifact`/`collect-elf-deps.sh` path) so it becomes a standard host-glibc artifact; its remaining closure measured 2.38, exactly at the floor.
5. **darwin floor > 13.0** → identify the offender; if it's from an SDK-14-built package, either pin `MACOS_FLOOR_MAX` per recipe (documented) or add the nixpkgs `darwinMinVersionHook` for a lower deployment target in the service's nix package.

Commit each fix separately and re-dispatch only the affected services: `gh workflow run service-artifacts.yml --ref <branch> -f services="postgres postgrest" -f force=true`.

---

### Task 8: Postgres portable-artifact interpreter remediation (contingent on Task 7)

**Files:**
- Modify: `services/postgres/nix/packages/postgres-portable.nix` (postFixup)
- Possibly modify: `services/postgres/recipe.env` (`FLOOR_CHECK_CMD` path fix)

Evidence from the stale tree (verify against the fresh CI artifact first): the rootfs ships a `nix/store/` subtree whose ELFs keep absolute `/nix/store/.../ld-linux-*.so.1` interpreters (e.g. `.postgres-wrapped` in `postgresql-and-plugins-17.6`), which resolve ONLY on machines that have those store paths — CI runners pass because they just built them. The upstream `postFixup` already patches `$out/bin/.*-wrapped` and `$out/lib/*.so*`; the bundled store subtree is missed.

- [ ] **Step 1: Reproduce with the fresh artifact**

Build linux-arm64 locally (Docker-hosted Nix; the upstream binary cache makes this mostly downloads):

```bash
TARGET_OS=linux ARCH=arm64 scripts/build-artifact.sh postgres 17.6.1.143
scripts/os-floor.sh --linux artifacts/postgres/17.6.1.143/linux-arm64/rootfs
bash scripts/audit-portable-artifact.sh --linux artifacts/postgres/17.6.1.143/linux-arm64/rootfs || true
```
Expected: the audit's interp gate lists the offending files (or passes, in which case skip to Step 3).

- [ ] **Step 2: Normalize every shipped ELF in the overlay postFixup**

In `services/postgres/nix/packages/postgres-portable.nix`, generalize the existing per-`$out/bin`/`$out/lib` patch loops: after them, walk the ENTIRE output and patch any remaining ELF (same INTERP variable already computed there):

```bash
# slim-services overlay: the portable output may carry a bundled store
# subtree (extension closures). Every shipped ELF must use the system
# loader and only relative rpaths — absolute store interpreters resolve
# only on the build machine.
find $out -type f | while read -r elf; do
  file "$elf" | grep -q ELF || continue
  interp="$(patchelf --print-interpreter "$elf" 2>/dev/null || true)"
  case "$interp" in
    /nix/store/*)
      patchelf --set-interpreter "$INTERP" "$elf" 2>/dev/null || true
      ;;
  esac
  rpath="$(patchelf --print-rpath "$elf" 2>/dev/null || true)"
  case "$rpath" in
    */nix/store/*)
      lib_rel="$(python3 -c "import os,sys; print(os.path.relpath(os.path.join(sys.argv[1],'lib'), os.path.dirname(sys.argv[2])))" "$out" "$elf")"
      patchelf --set-rpath "\$ORIGIN/$lib_rel" "$elf" 2>/dev/null || true
      ;;
  esac
done
```

If the bundled store subtree turns out to be UNUSED at runtime (nothing in `bin/`, `lib/`, `share/` resolves into it — check with `find rootfs -type l -exec readlink {} +` and the smoke), prefer deleting it in the overlay instead of patching it: smaller artifact, same portability.

- [ ] **Step 3: Validate the loop end-to-end**

```bash
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh postgres 17.6.1.143
```
Expected: audit passes (interp + floor gates), floor check runs `postgres --version`/`initdb --version` in fedora:39, image builds and smokes. Fix the `FLOOR_CHECK_CMD` binary paths here if the real layout differs.

- [ ] **Step 4: Commit and re-dispatch postgres in CI**

```bash
git add services/postgres/
git commit -m "postgres: normalize ELF interpreters/rpaths across the whole portable rootfs"
gh workflow run service-artifacts.yml --ref <branch> -f services="postgres" -f force=true
```

---

### Task 9: Results refresh and PR

- [ ] **Step 1: Merge the run's manifests into the results tables**

CI's `update-tables` job opens its own docs PR when numbers changed; verify it did (or run `scripts/update-results-tables.sh --merge` locally with the downloaded manifests placed per the workflow's layout).

- [ ] **Step 2: Update memory of the project state**

Update the `slim-services-project-state` memory file: floors measured (linux glibc 2.38 via ERTS, darwin minos 11.3), gates live, naming reservation (`-musl`), any per-service overrides granted in Task 7.

- [ ] **Step 3: Open the PR**

```bash
gh pr create --base main --title "Host portability: measured OS floors, audit gates, and floor-container execution proof" --body "$(cat <<'EOF'
Archives must be as portable as possible out of the box (no CLI-side relocation). This PR makes the host contract explicit and enforced:

- `scripts/os-floor.sh`: measures each artifact's OS floor (max GLIBC_x.y Verneed requirement on Linux, max Mach-O minos on macOS).
- Portable audit now gates: standard ELF interpreter only, glibc floor <= 2.38 (Ubuntu 24.04+/Debian 13+/Fedora 39+), macOS floor <= 13.0. Per-recipe overrides supported.
- Execution proof: every portable Linux artifact's launcher runs inside fedora:39 (glibc 2.38 exactly) via recipe `FLOOR_CHECK_CMD`.
- Manifests record `target`, `libc`, and the measured `os_floor` so the CLI can pre-flight hosts with a clear error.
- Target naming: `linux-<arch>` stays the glibc default (no `-gnu`); `linux-<arch>-musl` is reserved for future Alpine targets.
- (If Task 8 applied) postgres: normalized ELF interpreters across the whole portable rootfs — previously bundled-store ELFs only resolved on machines with the build store.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review Notes

- Floor values are MEASURED, not guessed: linux 2.38 (`beam.smp`, pinned nixpkgs `ac62194c`, aarch64-linux, via cache substitution), darwin 11.3 (same pin, aarch64-darwin). fedora:39 chosen because its glibc is exactly 2.38.
- The local `artifacts/` trees are stale; every expected value derived from them is labeled as such and used only to verify script mechanics.
- Task 4's BEAM `eval` env lists mirror each service's own smoke script verbatim; if a config provider still raises for a missing var, decision rule 3 in Task 7 covers the fix loop.
- `os-floor.sh` handles only 64-bit little-endian ELF — all supported targets (aarch64, x86_64). 32-bit/BE files return no requirements rather than crashing.
- Type consistency: the JSON contract (`kind`/`floor`/`offender`/`scanned`/`bundled_glibc`) is identical in Tasks 1, 2, 3, and 7's report script.
