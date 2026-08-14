#!/usr/bin/env python3
"""Validate and normalize a small, regular-file upstream release archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import tarfile
from typing import Any


class ArchiveError(ValueError):
    """An archive or normalization input violates the extraction contract."""


def _relative_path(value: Any, label: str, *, nested: bool) -> str:
    if not isinstance(value, str) or not value:
        raise ArchiveError(f"{label} must be a non-empty path")
    if value.startswith("/") or "\\" in value:
        raise ArchiveError(f"unsafe {label}: {value!r}")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ArchiveError(f"unsafe {label}: {value!r}")
    if not nested and len(parts) != 1:
        raise ArchiveError(f"unsafe {label}: {value!r}")
    return value


def _load_inputs(mapping_raw: str, executables_raw: str) -> tuple[dict[str, str], set[str]]:
    try:
        mapping_value = json.loads(mapping_raw)
        executables_value = json.loads(executables_raw)
    except json.JSONDecodeError as error:
        raise ArchiveError(f"mapping/executables JSON is invalid: {error.msg}") from error

    if not isinstance(mapping_value, dict):
        raise ArchiveError("mapping JSON must be an object")
    if not isinstance(executables_value, list):
        raise ArchiveError("executables JSON must be an array")

    mapping: dict[str, str] = {}
    destinations: set[str] = set()
    for source_value, destination_value in mapping_value.items():
        source = _relative_path(source_value, "mapping source", nested=True)
        destination = _relative_path(destination_value, "mapping destination", nested=True)
        if source in mapping:
            raise ArchiveError(f"duplicate mapping source: {source}")
        if destination in destinations:
            raise ArchiveError(f"duplicate destination: {destination}")
        mapping[source] = destination
        destinations.add(destination)

    executables: set[str] = set()
    for executable_value in executables_value:
        executable = _relative_path(executable_value, "executable", nested=True)
        if executable in executables:
            raise ArchiveError(f"duplicate executable: {executable}")
        executables.add(executable)
    unknown_executables = sorted(executables - mapping.keys())
    if unknown_executables:
        raise ArchiveError(
            "executables are absent from mapping: " + ", ".join(unknown_executables)
        )
    return mapping, executables


def _validate_members(
    archive: tarfile.TarFile, mapping: dict[str, str], executables: set[str]
) -> list[tuple[tarfile.TarInfo, str, str, int]]:
    members = archive.getmembers()
    seen_raw: set[str] = set()
    parsed: list[tuple[tarfile.TarInfo, str]] = []
    roots: set[str] = set()

    for member in members:
        raw_name = member.name
        if raw_name in seen_raw:
            raise ArchiveError(f"duplicate archive member: {raw_name}")
        seen_raw.add(raw_name)
        name = raw_name[2:] if raw_name.startswith("./") else raw_name
        normalized_name = name.rstrip("/") if member.isdir() else name
        _relative_path(normalized_name, "archive member path", nested=True)
        if not member.isreg() and not member.isdir():
            raise ArchiveError(f"non-regular archive member: {name}")
        mode = member.mode
        if not isinstance(mode, int) or mode < 0 or mode & ~0o777:
            raise ArchiveError(f"invalid archive mode: {name}")
        if member.isdir() and "/" not in normalized_name:
            roots.add(normalized_name)
        parsed.append((member, normalized_name))

    if len(roots) > 1:
        raise ArchiveError("multiple archive roots: " + ", ".join(sorted(roots)))
    root = next(iter(roots), None)
    normalized_members: list[tuple[tarfile.TarInfo, str | None]] = []
    root_member_seen = False
    for member, name in parsed:
        if root is not None:
            if name == root:
                normalized_name = None
            elif name.startswith(root + "/"):
                normalized_name = name[len(root) + 1 :]
            else:
                raise ArchiveError(f"multiple archive roots: {name}")
        else:
            normalized_name = name
        if normalized_name is not None:
            if root is None:
                _relative_path(normalized_name, "archive member path", nested=False)
            else:
                _relative_path(normalized_name, "normalized archive member path", nested=True)
        elif root_member_seen:
            raise ArchiveError(f"duplicate normalized archive member: {root}")
        else:
            root_member_seen = True
        normalized_members.append((member, normalized_name))

    seen_normalized: set[str] = set()
    regular_members: set[str] = set()
    validated: list[tuple[tarfile.TarInfo, str, str, int]] = []
    for member, name in normalized_members:
        if name is None:
            if member.isreg():
                raise ArchiveError(f"archive root is not a directory: {member.name}")
            continue
        if name in seen_normalized:
            raise ArchiveError(f"duplicate normalized archive member: {name}")
        seen_normalized.add(name)
        if member.isdir():
            continue
        regular_members.add(name)
        if name not in mapping:
            continue
        mode = member.mode
        is_executable = bool(mode & 0o111)
        if (name in executables) != is_executable:
            raise ArchiveError(f"executable mode mismatch: {name}")
        validated.append((member, name, mapping[name], mode & 0o777))

    expected = set(mapping)
    actual = regular_members
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        details = []
        if missing:
            details.append("missing=" + ",".join(missing))
        if extra:
            details.append("extra=" + ",".join(extra))
        raise ArchiveError("archive members do not match mapping (" + "; ".join(details) + ")")
    return validated


def _prepare_destinations(rootfs: pathlib.Path, destinations: list[str]) -> None:
    if rootfs.exists() and (not rootfs.is_dir() or rootfs.is_symlink()):
        raise ArchiveError(f"rootfs is not a safe directory: {rootfs}")
    rootfs.mkdir(parents=True, exist_ok=True)
    for destination in destinations:
        destination_path = rootfs.joinpath(*destination.split("/"))
        parent = destination_path.parent
        relative_parent = parent.relative_to(rootfs)
        current = rootfs
        for component in relative_parent.parts:
            current = current / component
            if current.is_symlink() or (current.exists() and not current.is_dir()):
                raise ArchiveError(f"destination parent is not a directory: {destination}")
            current.mkdir(exist_ok=True)
        if destination_path.is_symlink():
            raise ArchiveError(f"destination is a symlink: {destination}")
        if destination_path.exists() and not destination_path.is_file():
            raise ArchiveError(f"destination is not a regular file: {destination}")


def _install(
    archive: tarfile.TarFile,
    rootfs: pathlib.Path,
    validated: list[tuple[tarfile.TarInfo, str, str, int]],
) -> dict[str, dict[str, str]]:
    report: dict[str, dict[str, str]] = {}
    for member, source, destination, mode in sorted(validated, key=lambda item: item[1]):
        destination_path = rootfs.joinpath(*destination.split("/"))
        source_digest = hashlib.sha256()
        destination_digest = hashlib.sha256()
        bytes_read = 0
        extracted = archive.extractfile(member)
        if extracted is None:
            raise ArchiveError(f"could not read regular archive member: {member.name}")
        try:
            with extracted, destination_path.open("wb") as output:
                for chunk in iter(lambda: extracted.read(1024 * 1024), b""):
                    bytes_read += len(chunk)
                    source_digest.update(chunk)
                    destination_digest.update(chunk)
                    output.write(chunk)
        except (OSError, tarfile.TarError) as error:
            raise ArchiveError(f"could not install archive member: {member.name}") from error
        if bytes_read != member.size:
            raise ArchiveError(f"archive member size mismatch: {member.name}")
        try:
            os.chmod(destination_path, mode)
        except OSError as error:
            raise ArchiveError(f"could not set mode for archive member: {member.name}") from error
        report[source] = {
            "destination": destination,
            "source_sha256": source_digest.hexdigest(),
            "destination_sha256": destination_digest.hexdigest(),
        }
    return report


def normalize(
    archive_path: pathlib.Path,
    rootfs: pathlib.Path,
    mapping_raw: str,
    executables_raw: str,
) -> dict[str, dict[str, dict[str, str]]]:
    mapping, executables = _load_inputs(mapping_raw, executables_raw)
    if not mapping:
        raise ArchiveError("mapping JSON must not be empty")
    try:
        with tarfile.open(archive_path, "r:*") as archive:
            validated = _validate_members(archive, mapping, executables)
            _prepare_destinations(rootfs, [destination for _, _, destination, _ in validated])
            report = _install(archive, rootfs, validated)
    except (OSError, tarfile.TarError) as error:
        raise ArchiveError(f"could not read archive: {archive_path}") from error
    return {"members": report}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("rootfs", type=pathlib.Path)
    parser.add_argument("mapping_json")
    parser.add_argument("executables_json")
    args = parser.parse_args()
    try:
        report = normalize(args.archive, args.rootfs, args.mapping_json, args.executables_json)
    except ArchiveError as error:
        print(f"error: {error}", file=os.sys.stderr)
        return 1
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
