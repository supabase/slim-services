#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: services/studio/normalize-next-standalone.sh STANDALONE_ROOT INSTALLED_PNPM_STORE

Materialize exact dangling pnpm alias targets from the installed build store
while preserving the generated symlinks.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

standalone_root="$1"
installed_store="$2"
[[ -d "$standalone_root" ]] || {
  printf '[slim] ERROR: standalone tree not found: %s\n' "$standalone_root" >&2
  exit 1
}
[[ -d "$installed_store" ]] || {
  printf '[slim] ERROR: installed pnpm store not found: %s\n' "$installed_store" >&2
  exit 1
}

# Next's standalone tracing can retain pnpm aliases for packages used only by
# the build graph. Copy the exact package target from the frozen installed
# store into the standalone store, leaving the alias symlink unchanged.
python3 - "$standalone_root" "$installed_store" <<'PY'
from __future__ import annotations

import os
import pathlib
import shutil
import sys


standalone = pathlib.Path(sys.argv[1]).resolve()
installed = pathlib.Path(sys.argv[2]).resolve()


def inside(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        path.relative_to(root)
    except ValueError:
        return False
    return True


def report_scan_error(error: OSError) -> None:
    location = error.filename or standalone
    raise SystemExit(f"{location}: cannot scan directory ({error})")


def pnpm_store_root(link: pathlib.Path) -> pathlib.Path | None:
    relative = link.relative_to(standalone)
    parts = relative.parts
    for index in range(len(parts) - 2):
        if parts[index : index + 3] == ("node_modules", ".pnpm", "node_modules"):
            return standalone.joinpath(*parts[: index + 2])
    return None


repairs: list[tuple[pathlib.Path, pathlib.Path, pathlib.Path]] = []
for directory, dirnames, filenames in os.walk(
    standalone, topdown=True, onerror=report_scan_error, followlinks=False
):
    dirnames.sort()
    filenames.sort()
    for name in (*dirnames, *filenames):
        link = pathlib.Path(directory) / name
        if not link.is_symlink():
            continue
        target = os.readlink(link)
        if target == "":
            raise SystemExit(f"{link}: empty symlink target (cannot resolve)")
        if os.path.isabs(target):
            raise SystemExit(f"{link} -> {target}: absolute symlink (not relocatable)")
        candidate = pathlib.Path(os.path.realpath(link))
        if not inside(candidate, standalone):
            raise SystemExit(
                f"{link} -> {target}: resolves outside standalone tree ({candidate})"
            )
        try:
            link.resolve(strict=True)
        except FileNotFoundError:
            store_root = pnpm_store_root(link)
            if store_root is None:
                raise SystemExit(
                    f"{link} -> {target}: dangling symlink is not a pnpm alias"
                )
            try:
                relative_target = candidate.relative_to(store_root)
            except ValueError:
                raise SystemExit(
                    f"{link} -> {target}: pnpm target is outside its store"
                )
            source = installed / relative_target
            if not inside(source, installed):
                raise SystemExit(
                    f"{link} -> {target}: installed pnpm target is outside the store"
                )
            try:
                source_resolved = source.resolve(strict=True)
            except FileNotFoundError:
                raise SystemExit(
                    f"{link} -> {target}: installed pnpm target not found: {source}"
                )
            except (OSError, RuntimeError) as error:
                raise SystemExit(
                    f"{link} -> {target}: installed pnpm target cannot resolve: {error}"
                )
            if not inside(source_resolved, installed):
                raise SystemExit(
                    f"{link} -> {target}: installed pnpm target resolves outside the store"
                )
            repairs.append((link, candidate, source))
        except (OSError, RuntimeError) as error:
            raise SystemExit(f"{link} -> {target}: cannot resolve symlink ({error})")

for link, destination, source in repairs:
    if os.path.lexists(destination):
        raise SystemExit(f"{link}: pnpm target destination already exists: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        os.symlink(os.readlink(source), destination)
    elif source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination, follow_symlinks=False)

# Next 15.5.25+ traces sharp's .node without optional sharp-libvips. Copy the
# matching prebuild so the .node $ORIGIN sibling rpath can resolve.
standalone_stores: list[pathlib.Path] = []
for directory, dirnames, _filenames in os.walk(
    standalone, topdown=True, onerror=report_scan_error, followlinks=False
):
    dirnames.sort()
    path = pathlib.Path(directory)
    if path.name == ".pnpm" and path.parent.name == "node_modules":
        standalone_stores.append(path)
for store in standalone_stores:
    for sharp_node in store.glob(
        "@img+sharp-*/node_modules/@img/sharp-*/lib/*.node"
    ):
        sharp_pkg = sharp_node.parent.parent
        arch_name = sharp_pkg.name
        if not (
            arch_name.startswith("sharp-linux-")
            or arch_name.startswith("sharp-darwin-")
        ):
            continue
        libvips_name = "sharp-libvips-" + arch_name.removeprefix("sharp-")
        sibling = sharp_pkg.parent / libvips_name
        if sibling.exists():
            continue
        matches = sorted(
            installed.glob(f"@img+{libvips_name}@*/node_modules/@img/{libvips_name}")
        )
        if not matches:
            raise SystemExit(
                f"{sharp_node}: missing optional {libvips_name} in installed pnpm store"
            )
        source = matches[-1]
        store_pkg = source.parents[2]
        dest_store = store / store_pkg.name
        if not dest_store.exists():
            if not inside(source, installed):
                raise SystemExit(
                    f"{sharp_node}: installed {libvips_name} is outside the store"
                )
            shutil.copytree(store_pkg, dest_store, symlinks=True)
        dest_pkg = dest_store / "node_modules" / "@img" / libvips_name
        sibling.symlink_to(os.path.relpath(dest_pkg, sibling.parent))
PY
