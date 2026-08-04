#!/usr/bin/env python3
"""Generate a deterministic SPDX 2.3 file-level SBOM for a runtime tree."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path


def checksums(path: Path) -> tuple[str, str]:
    sha1 = hashlib.sha1(usedforsecurity=False)
    sha256 = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha1.update(chunk)
            sha256.update(chunk)
    return sha1.hexdigest(), sha256.hexdigest()


def spdx_id(relative_path: str) -> str:
    digest = hashlib.sha256(relative_path.encode()).hexdigest()[:24]
    return f"SPDXRef-File-{digest}"


def created_at() -> str:
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    timestamp = dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc)
    return timestamp.strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("rootfs", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--service", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()

    if not args.rootfs.is_dir():
        parser.error(f"rootfs does not exist: {args.rootfs}")

    files = []
    file_sha1s = []
    namespace_digest = hashlib.sha256()
    for path in sorted(candidate for candidate in args.rootfs.rglob("*") if candidate.is_file()):
        relative_path = path.relative_to(args.rootfs).as_posix()
        sha1, sha256 = checksums(path)
        file_sha1s.append(sha1)
        namespace_digest.update(relative_path.encode())
        namespace_digest.update(b"\0")
        namespace_digest.update(sha256.encode())
        namespace_digest.update(b"\n")
        files.append(
            {
                "fileName": f"./{relative_path}",
                "SPDXID": spdx_id(relative_path),
                "checksums": [
                    {"algorithm": "SHA1", "checksumValue": sha1},
                    {"algorithm": "SHA256", "checksumValue": sha256},
                ],
                "licenseConcluded": "NOASSERTION",
                "copyrightText": "NOASSERTION",
            }
        )

    artifact_name = f"{args.service}-{args.version}-{args.target}"
    package_id = "SPDXRef-Package-runtime"
    verification_code = hashlib.sha1(usedforsecurity=False)
    verification_code.update("".join(sorted(file_sha1s)).encode())
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": artifact_name,
        "documentNamespace": (
            "https://github.com/supabase/slim-services/sbom/"
            f"{artifact_name}/{namespace_digest.hexdigest()}"
        ),
        "creationInfo": {
            "created": created_at(),
            "creators": ["Tool: slim-services/generate-artifact-sbom.py"],
        },
        "documentDescribes": [package_id],
        "packages": [
            {
                "name": artifact_name,
                "SPDXID": package_id,
                "versionInfo": args.version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": True,
                "packageVerificationCode": {
                    "packageVerificationCodeValue": verification_code.hexdigest()
                },
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "copyrightText": "NOASSERTION",
            }
        ],
        "files": files,
        "relationships": [
            {
                "spdxElementId": package_id,
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": file_entry["SPDXID"],
            }
            for file_entry in files
        ],
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=2, sort_keys=True)
        stream.write("\n")


if __name__ == "__main__":
    main()
