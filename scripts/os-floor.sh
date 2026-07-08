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
        if off + size > len(data):  # malformed sh_offset/sh_size: skip, don't crash
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
        # A malformed/truncated ELF must never crash the scan; treat it as
        # contributing no requirements.
        try:
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
        except (struct.error, ValueError, IndexError):
            continue

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
