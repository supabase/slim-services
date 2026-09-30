#!/usr/bin/env python3
"""Backport upstream's self-hosted sharp exclusion into Studio's next.config.

Next 15.5.25+ / 16.3.5 traces the optional `sharp` package (and its `@img/*`
native binaries) into `.next/standalone` unless the config both marks images
`unoptimized` for the self-hosted build and excludes those packages from
output file tracing. Upstream added this in supabase/supabase#50658. Studio
sources built before that PR need the same edit applied at build time so the
slim-services standalone output never ships sharp's native binaries; sources
that already carry the exclusion are left byte-identical.
"""

from __future__ import annotations

import pathlib
import sys

# The literal marker upstream's own exclusion always contains. A source whose
# next.config already has this already keeps sharp out of standalone output
# and must not be touched.
ALREADY_EXCLUDED_MARKER = "node_modules/sharp"

# Anchor 1: the `images` object. Insert `unoptimized` as its first entry, same
# as upstream, so the self-hosted build serves plain <img> and never needs
# sharp at runtime either.
IMAGES_ANCHOR = "\n  images: {\n"
UNOPTIMIZED_EDIT = (
    "    // Self-hosted: serve plain <img> (as the TanStack shim does) so Next never\n"
    "    // loads sharp. Hosted Studio optimizes images on Vercel.\n"
    "    unoptimized: process.env.NEXT_PUBLIC_IS_PLATFORM !== 'true',\n"
)

# Anchor 2: the top-level config object, right where the `images` entry closes
# and `transpilePackages` begins. Insert the trace exclusion between them.
EXCLUDES_ANCHOR = "\n  },\n  transpilePackages: ["
EXCLUDES_EDIT = (
    "  // Keep Next's optional sharp dependency out of the self-hosted standalone\n"
    "  // output. It is unused with `unoptimized` above, and its native binaries\n"
    "  // break the slim-services Studio image (sharp's .node segfaults without\n"
    "  // libvips). Globs resolve from `apps/studio`; `../../` anchors them at the\n"
    "  // repo root where pnpm hoists the store.\n"
    "  ...(process.env.NEXT_PUBLIC_IS_PLATFORM === 'true'\n"
    "    ? {}\n"
    "    : {\n"
    "        outputFileTracingExcludes: {\n"
    "          '*': ['../../**/node_modules/sharp/**/*', '../../**/node_modules/@img/**/*'],\n"
    "        },\n"
    "      }),\n"
)


def backport(original: str, config_path: pathlib.Path) -> str | None:
    """Return the patched config text, or None if already excluded."""
    if ALREADY_EXCLUDED_MARKER in original:
        return None

    images_count = original.count(IMAGES_ANCHOR)
    if images_count != 1:
        raise SystemExit(
            f"backport-sharp-exclusion: {config_path}: expected exactly one "
            f"'images: {{' anchor, found {images_count}"
        )

    excludes_count = original.count(EXCLUDES_ANCHOR)
    if excludes_count != 1:
        raise SystemExit(
            f"backport-sharp-exclusion: {config_path}: expected exactly one "
            f"images-closing/transpilePackages anchor, found {excludes_count}"
        )

    patched = original.replace(IMAGES_ANCHOR, IMAGES_ANCHOR + UNOPTIMIZED_EDIT, 1)
    patched = patched.replace(
        EXCLUDES_ANCHOR, "\n  },\n" + EXCLUDES_EDIT + "  transpilePackages: [", 1
    )
    return patched


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} NEXT_CONFIG_PATH", file=sys.stderr)
        return 2
    config_path = pathlib.Path(argv[1])
    if not config_path.is_file():
        print(f"backport-sharp-exclusion: next.config not found: {config_path}", file=sys.stderr)
        return 1

    original = config_path.read_text(encoding="utf-8")
    patched = backport(original, config_path)
    if patched is None:
        print(
            f"[slim] {config_path}: sharp already excluded from output file tracing, "
            "leaving unchanged"
        )
        return 0

    config_path.write_text(patched, encoding="utf-8")
    print(f"[slim] {config_path}: backported self-hosted sharp exclusion")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
