#!/usr/bin/env python3
"""Validate that every artifact symlink resolves inside its artifact root."""

from __future__ import annotations

import os
import pathlib
import sys


def validate(root: pathlib.Path) -> list[str]:
    root = root.resolve()
    failures: list[str] = []

    def report_scan_error(error: OSError) -> None:
        location = error.filename or root
        failures.append(f"{location}: cannot scan directory ({error})")

    for directory, dirnames, filenames in os.walk(
        root, topdown=True, onerror=report_scan_error, followlinks=False
    ):
        dirnames.sort()
        filenames.sort()
        for name in (*dirnames, *filenames):
            link = pathlib.Path(directory) / name
            if not link.is_symlink():
                continue
            target = os.readlink(link)
            if target == "":
                failures.append(f"{link}: empty symlink target (cannot resolve)")
                continue
            if os.path.isabs(target):
                failures.append(f"{link} -> {target}: absolute symlink (not relocatable)")
                continue
            candidate = pathlib.Path(os.path.realpath(link))
            try:
                candidate.relative_to(root)
            except ValueError:
                failures.append(f"{link} -> {target}: resolves outside artifact root ({candidate})")
                continue
            try:
                # Path.resolve() is lexical on older Python versions and can
                # collapse malformed targets such as regular-file/.. to a
                # different existing path. os.stat follows the link through
                # the kernel and preserves the ENOTDIR failure semantics.
                link.stat()
            except FileNotFoundError:
                failures.append(f"{link} -> {target}: dangling symlink ({candidate})")
                continue
            except OSError as error:
                failures.append(f"{link} -> {target}: cannot resolve symlink ({error})")
                continue
            try:
                resolved = link.resolve(strict=True)
            except FileNotFoundError:
                failures.append(f"{link} -> {target}: dangling symlink ({candidate})")
                continue
            except (OSError, RuntimeError) as error:
                failures.append(f"{link} -> {target}: cannot resolve symlink ({error})")
                continue
            try:
                resolved.relative_to(root)
            except ValueError:
                failures.append(f"{link} -> {target}: resolves outside artifact root ({resolved})")
                continue
    return sorted(failures)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} ROOTFS", file=sys.stderr)
        return 2
    root = pathlib.Path(argv[1])
    if not root.is_dir():
        print(f"rootfs directory not found: {root}", file=sys.stderr)
        return 2
    failures = validate(root)
    if failures:
        print("artifact symlink validation failed:", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
