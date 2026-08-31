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
PY
