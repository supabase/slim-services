#!/usr/bin/env python3
"""Lower a macOS Mach-O's minimum deployment target (minos) in place.

Usage: scripts/lower-macho-minos.py TARGET_MINOS FILE...

Some upstream macOS release binaries are built on a newer runner image and
pick up that image's default deployment target (for example PostgREST v16.6
moved from minos 14.0 to 15.0) without importing any newer-OS symbol. When a
file's macOS minos is above TARGET_MINOS this rewrites the minos field of its
LC_BUILD_VERSION / LC_VERSION_MIN_MACOSX load command to TARGET_MINOS. Files
already at or below TARGET_MINOS are left byte-for-byte untouched, so older
releases keep their exact upstream bytes. The SDK version and every other
byte are preserved. minos is only ever lowered, never raised.

This is metadata only: it is sound solely when the binary does not need
anything newer than TARGET_MINOS at runtime. The caller must justify that
(identical imported symbols/libraries to a release that shipped at
TARGET_MINOS). The edit invalidates any code signature; re-sign afterwards.
"""

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF  # little-endian 64-bit slice
FAT_MAGIC = 0xCAFEBABE  # big-endian fat header
FAT_MAGIC_64 = 0xCAFEBABF

LC_VERSION_MIN_MACOSX = 0x24
LC_BUILD_VERSION = 0x32
PLATFORM_MACOS = 1


def parse_version(text):
    parts = [int(p) for p in text.split(".")]
    if not 1 <= len(parts) <= 3 or any(p < 0 for p in parts):
        raise ValueError(f"invalid version: {text}")
    parts += [0] * (3 - len(parts))
    major, minor, patch = parts
    if major > 0xFFFF or minor > 0xFF or patch > 0xFF:
        raise ValueError(f"version out of range: {text}")
    return (major << 16) | (minor << 8) | patch


def format_version(value):
    major, minor, patch = value >> 16, (value >> 8) & 0xFF, value & 0xFF
    return f"{major}.{minor}" + (f".{patch}" if patch else "")


def slice_offsets(data):
    """Yield the file offset of each Mach-O slice in DATA."""
    if len(data) < 8:
        return
    magic_be = struct.unpack_from(">I", data, 0)[0]
    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        wide = magic_be == FAT_MAGIC_64
        entry = 32 if wide else 20
        for index in range(count):
            base = 8 + index * entry
            offset = struct.unpack_from(">Q" if wide else ">I", data, base + 8)[0]
            yield offset
    elif struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64:
        yield 0


def lower_file(path, target):
    with open(path, "rb") as stream:
        data = bytearray(stream.read())
    changed = []
    for base in slice_offsets(data):
        if struct.unpack_from("<I", data, base)[0] != MH_MAGIC_64:
            raise SystemExit(f"{path}: unsupported Mach-O slice at {base}")
        ncmds = struct.unpack_from("<I", data, base + 16)[0]
        cursor = base + 32  # sizeof(mach_header_64)
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, cursor)
            if cmd == LC_BUILD_VERSION:
                platform, minos = struct.unpack_from("<II", data, cursor + 8)
                field = cursor + 12
                is_macos = platform == PLATFORM_MACOS
            elif cmd == LC_VERSION_MIN_MACOSX:
                minos = struct.unpack_from("<I", data, cursor + 8)[0]
                field = cursor + 8
                is_macos = True
            else:
                field = None
            if field is not None and is_macos and minos > target:
                struct.pack_into("<I", data, field, target)
                changed.append((minos, target))
            if cmdsize < 8:
                raise SystemExit(f"{path}: corrupt load command size {cmdsize}")
            cursor += cmdsize
    if changed:
        with open(path, "wb") as stream:
            stream.write(data)
    return changed


def main(argv):
    if len(argv) < 3 or argv[1] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    target = parse_version(argv[1])
    for path in argv[2:]:
        changed = lower_file(path, target)
        if changed:
            old = format_version(changed[0][0])
            print(
                f"[slim] lowered minos {old} -> {format_version(target)}: {path}"
            )
        else:
            print(f"[slim] minos already <= {format_version(target)}: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
