#!/usr/bin/env python3
"""Record the verified normalized archive digest in an artifact manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re


DIGEST_LINE = re.compile(r"^([0-9a-fA-F]{64})[ \t]+\*?(.+?)\s*$")


def archive_digest(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sidecar_digest(sidecar: pathlib.Path, archive: pathlib.Path) -> str:
    matches: list[str] = []
    with sidecar.open(encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            match = DIGEST_LINE.fullmatch(line.rstrip("\n"))
            if match is None:
                raise ValueError(f"invalid checksum sidecar line: {line.rstrip()}")
            name = match.group(2)
            if name in {archive.name, f"./{archive.name}"}:
                matches.append(match.group(1).lower())
    if not matches:
        raise ValueError(f"missing checksum sidecar entry for {archive.name}")
    if len(matches) != 1:
        raise ValueError(f"duplicate checksum sidecar entries for {archive.name}")
    return matches[0]


def record(manifest_path: pathlib.Path, archive: pathlib.Path, sidecar: pathlib.Path) -> str:
    expected = sidecar_digest(sidecar, archive)
    actual = archive_digest(archive)
    if expected != actual:
        raise ValueError(
            f"archive digest mismatch for {archive.name}: expected {expected}, got {actual}"
        )

    with manifest_path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be a JSON object")

    provenance = manifest.setdefault("provenance", {})
    if not isinstance(provenance, dict):
        raise ValueError("manifest provenance must be an object")
    provenance["normalized_archive"] = {"name": archive.name, "sha256": actual}
    manifest["archive_sha256"] = actual
    with manifest_path.open("w", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2, sort_keys=True)
        stream.write("\n")
    return actual


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("sha256sums", type=pathlib.Path)
    args = parser.parse_args()
    try:
        print(record(args.manifest, args.archive, args.sha256sums))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
