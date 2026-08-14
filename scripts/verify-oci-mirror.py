#!/usr/bin/env python3
"""Verify that a destination contains an exact copy of a pinned OCI index."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import pathlib
import re
import sys
from typing import Any


OCI_INDEX_MEDIA_TYPE = "application/vnd.oci.image.index.v1+json"
DOCKER_MANIFEST_LIST_MEDIA_TYPE = "application/vnd.docker.distribution.manifest.list.v2+json"
OCI_MANIFEST_MEDIA_TYPE = "application/vnd.oci.image.manifest.v1+json"
DOCKER_MANIFEST_MEDIA_TYPE = "application/vnd.docker.distribution.manifest.v2+json"
IMAGE_DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
REQUIRED_PLATFORMS = ("linux/amd64", "linux/arm64")


class VerificationError(ValueError):
    """An OCI index does not satisfy the exact mirror contract."""


def _load_resolver() -> Any:
    resolver_path = pathlib.Path(__file__).with_name("upstream-release.py")
    spec = importlib.util.spec_from_file_location("upstream_release", resolver_path)
    if spec is None or spec.loader is None:
        raise VerificationError(f"could not load policy resolver: {resolver_path}")
    resolver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(resolver)
    return resolver


def _digest(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def _descriptor_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or IMAGE_DIGEST.fullmatch(value) is None:
        raise VerificationError(f"{label} must be a sha256 digest")
    return value


def _platform_name(platform: Any, label: str) -> str | None:
    if platform is None:
        return None
    if not isinstance(platform, dict):
        raise VerificationError(f"{label}.platform must be an object")
    os_name = platform.get("os")
    architecture = platform.get("architecture")
    if not isinstance(os_name, str) or not isinstance(architecture, str):
        raise VerificationError(f"{label}.platform must define os and architecture")
    return f"{os_name}/{architecture}"


def _is_attestation(descriptor: dict[str, Any]) -> bool:
    annotations = descriptor.get("annotations")
    return isinstance(annotations, dict) and (
        annotations.get("vnd.docker.reference.type") == "attestation-manifest"
    )


def _validate_index(raw: bytes, label: str) -> tuple[dict[str, Any], str]:
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"{label} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"{label} must be an OCI index object")
    if value.get("schemaVersion") != 2:
        raise VerificationError(f"{label} has unexpected schemaVersion")
    index_media_type = value.get("mediaType")
    if index_media_type not in {
        OCI_INDEX_MEDIA_TYPE,
        DOCKER_MANIFEST_LIST_MEDIA_TYPE,
    }:
        raise VerificationError(
            f"{label} has unexpected media type: {index_media_type!r}"
        )
    child_media_type = (
        OCI_MANIFEST_MEDIA_TYPE
        if index_media_type == OCI_INDEX_MEDIA_TYPE
        else DOCKER_MANIFEST_MEDIA_TYPE
    )
    manifests = value.get("manifests")
    if not isinstance(manifests, list) or not manifests:
        raise VerificationError(f"{label}.manifests must be a non-empty array")

    platforms: dict[str, dict[str, Any]] = {}
    for index, descriptor in enumerate(manifests):
        descriptor_label = f"{label}.manifests[{index}]"
        if not isinstance(descriptor, dict):
            raise VerificationError(f"{descriptor_label} must be an object")
        if descriptor.get("mediaType") != child_media_type:
            raise VerificationError(
                f"{descriptor_label} has unexpected media type: "
                f"{descriptor.get('mediaType')!r} for {index_media_type}"
            )
        _descriptor_digest(descriptor.get("digest"), f"{descriptor_label}.digest")
        size = descriptor.get("size")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise VerificationError(f"{descriptor_label}.size must be a non-negative integer")
        platform_name = _platform_name(descriptor.get("platform"), descriptor_label)
        if platform_name in REQUIRED_PLATFORMS:
            if platform_name in platforms:
                raise VerificationError(f"{label} has duplicate platform {platform_name}")
            platforms[platform_name] = descriptor

    missing = [platform for platform in REQUIRED_PLATFORMS if platform not in platforms]
    if missing:
        raise VerificationError(f"{label} is missing platform(s): {', '.join(missing)}")
    return value, _digest(raw)


def _descriptor_key(descriptor: dict[str, Any]) -> str:
    return json.dumps(descriptor, sort_keys=True, separators=(",", ":"))


def verify(
    policy_path: pathlib.Path,
    version: str,
    source_path: pathlib.Path,
    destination_path: pathlib.Path,
    output_path: pathlib.Path,
) -> dict[str, Any]:
    resolver = _load_resolver()
    try:
        policy = resolver.load_policy(policy_path)
        image = resolver.resolve_image(policy, version)
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise VerificationError(f"could not resolve image policy: {error}") from error

    try:
        source_raw = source_path.read_bytes()
        destination_raw = destination_path.read_bytes()
    except OSError as error:
        raise VerificationError(f"could not read raw OCI index: {error}") from error

    source, source_digest = _validate_index(source_raw, "source index")
    destination, destination_digest = _validate_index(destination_raw, "destination index")

    expected_index_digest = image["index_digest"]
    if source_digest != expected_index_digest:
        raise VerificationError(
            f"source index digest mismatch: expected {expected_index_digest}, got {source_digest}"
        )

    source_platforms = {
        platform: descriptor["digest"]
        for platform, descriptor in (
            (platform, next(
                descriptor
                for descriptor in source["manifests"]
                if _platform_name(descriptor.get("platform"), "source descriptor") == platform
            ))
            for platform in REQUIRED_PLATFORMS
        )
    }
    for platform in REQUIRED_PLATFORMS:
        expected = image["platforms"][platform]
        actual = source_platforms[platform]
        if actual != expected:
            raise VerificationError(
                f"source platform {platform} digest mismatch: expected {expected}, got {actual}"
            )

    source_attestations = [
        descriptor
        for descriptor in source["manifests"]
        if _is_attestation(descriptor)
    ]
    destination_attestation_keys = {
        _descriptor_key(descriptor)
        for descriptor in destination["manifests"]
        if _is_attestation(descriptor)
    }
    for descriptor in source_attestations:
        if _descriptor_key(descriptor) not in destination_attestation_keys:
            raise VerificationError(
                "destination lost embedded attestation descriptor: " + descriptor["digest"]
            )

    if destination_digest != source_digest:
        raise VerificationError(
            f"destination index digest mismatch: expected {source_digest}, got {destination_digest}"
        )
    if destination_raw != source_raw:
        raise VerificationError("destination index raw bytes differ from source index")

    destination_platforms = {
        platform: descriptor["digest"]
        for platform, descriptor in (
            (platform, next(
                descriptor
                for descriptor in destination["manifests"]
                if _platform_name(descriptor.get("platform"), "destination descriptor")
                == platform
            ))
            for platform in REQUIRED_PLATFORMS
        )
    }
    if destination_platforms != source_platforms:
        raise VerificationError("destination platform descriptors differ from source index")

    provenance: dict[str, Any] = {
        "kind": "exact-oci-mirror",
        "version": version,
        "source": image["source"],
        "pinned_index_digest": expected_index_digest,
        "source_index_digest": source_digest,
        "destination_index_digest": destination_digest,
        "source_index_bytes": len(source_raw),
        "destination_index_bytes": len(destination_raw),
        "manifest_digests": [descriptor["digest"] for descriptor in source["manifests"]],
        "platforms": {platform: source_platforms[platform] for platform in REQUIRED_PLATFORMS},
        "embedded_attestations": [descriptor["digest"] for descriptor in source_attestations],
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        with output_path.open("w", encoding="utf-8") as stream:
            json.dump(provenance, stream, indent=2, sort_keys=True)
            stream.write("\n")
    except OSError as error:
        raise VerificationError(f"could not write provenance: {error}") from error
    return provenance


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("policy", type=pathlib.Path)
    parser.add_argument("version")
    parser.add_argument("source_raw_index", type=pathlib.Path)
    parser.add_argument("destination_raw_index", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        verify(
            args.policy,
            args.version,
            args.source_raw_index,
            args.destination_raw_index,
            args.output,
        )
    except VerificationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"verified exact OCI index: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
