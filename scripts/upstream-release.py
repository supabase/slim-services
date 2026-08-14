#!/usr/bin/env python3
"""Validate and resolve pinned upstream release assets."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
from typing import Any


NATIVE_TARGETS = frozenset({"darwin-arm64", "linux-amd64", "linux-arm64"})
IMAGE_PLATFORMS = frozenset({"linux/amd64", "linux/arm64"})
VERSION_PATTERN = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+\Z")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
HEX_DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
IMAGE_DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}\Z")


def _require_dict(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{path} must be an object")
    return value


def _require_keys(value: dict[str, Any], expected: set[str], path: str) -> None:
    actual = set(value)
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing:
        raise ValueError(f"{path} missing required keys: {', '.join(missing)}")
    if unexpected:
        raise ValueError(f"{path} has unexpected keys: {', '.join(unexpected)}")


def _require_string(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{path} must be a non-empty string")
    return value


def _validate_version(version: Any, path: str) -> str:
    version = _require_string(version, path)
    if VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError(f"{path} must be a canonical vMAJOR.MINOR.PATCH version")
    return version


def _validate_repository(repository: Any, path: str) -> str:
    repository = _require_string(repository, path)
    if REPOSITORY_PATTERN.fullmatch(repository) is None:
        raise ValueError(f"{path} must be an owner/name repository")
    return repository


def _validate_archive_digest(value: Any, path: str) -> str:
    value = _require_string(value, path)
    if HEX_DIGEST_PATTERN.fullmatch(value) is None:
        raise ValueError(f"{path} must be a lowercase SHA-256 digest")
    return value


def _validate_image_digest(value: Any, path: str) -> str:
    value = _require_string(value, path)
    if IMAGE_DIGEST_PATTERN.fullmatch(value) is None:
        raise ValueError(f"{path} must be a sha256: digest")
    return value


def _validate_asset(asset: Any, repository: str, version: str, target: str, path: str) -> dict[str, str]:
    asset = _require_dict(asset, path)
    _require_keys(asset, {"name", "url", "sha256"}, path)

    name = _require_string(asset["name"], f"{path}.name")
    expected_name = f"mailpit-{version}-{target}.tar.gz"
    if name != expected_name:
        raise ValueError(f"{path}.name must be {expected_name!r}")

    url = _require_string(asset["url"], f"{path}.url")
    expected_url = f"https://github.com/{repository}/releases/download/{version}/{name}"
    if url != expected_url:
        raise ValueError(f"{path}.url must be the canonical GitHub release URL {expected_url!r}")

    sha256 = _validate_archive_digest(asset["sha256"], f"{path}.sha256")
    return {"name": name, "url": url, "sha256": sha256}


def _validate_image(image: Any, repository: str, version: str, path: str) -> dict[str, Any]:
    image = _require_dict(image, path)
    _require_keys(image, {"source", "index_digest", "platforms"}, path)

    source = _require_string(image["source"], f"{path}.source")
    expected_source = f"docker.io/{repository}:{version}"
    if source != expected_source:
        raise ValueError(f"{path}.source must be {expected_source!r}")

    index_digest = _validate_image_digest(image["index_digest"], f"{path}.index_digest")
    platforms = _require_dict(image["platforms"], f"{path}.platforms")
    _require_keys(platforms, set(IMAGE_PLATFORMS), f"{path}.platforms")
    validated_platforms = {
        platform: _validate_image_digest(platforms[platform], f"{path}.platforms.{platform}")
        for platform in sorted(IMAGE_PLATFORMS)
    }
    return {
        "source": source,
        "index_digest": index_digest,
        "platforms": validated_platforms,
    }


def _validate_version_record(version_record: Any, repository: str, version: str, path: str) -> dict[str, Any]:
    version_record = _require_dict(version_record, path)
    _require_keys(version_record, {"assets", "image"}, path)

    assets = _require_dict(version_record["assets"], f"{path}.assets")
    _require_keys(assets, set(NATIVE_TARGETS), f"{path}.assets")
    validated_assets = {
        target: _validate_asset(assets[target], repository, version, target, f"{path}.assets.{target}")
        for target in sorted(NATIVE_TARGETS)
    }
    validated_image = _validate_image(version_record["image"], repository, version, f"{path}.image")
    return {"assets": validated_assets, "image": validated_image}


def load_policy(path: pathlib.Path) -> dict[str, Any]:
    """Load a release policy and reject anything outside its strict schema."""

    with path.open(encoding="utf-8") as stream:
        policy = json.load(stream)
    policy = _require_dict(policy, "policy")
    _require_keys(policy, {"repository", "versions"}, "policy")

    repository = _validate_repository(policy["repository"], "policy.repository")
    versions = _require_dict(policy["versions"], "policy.versions")
    if not versions:
        raise ValueError("policy.versions must not be empty")

    validated_versions: dict[str, Any] = {}
    for version, version_record in versions.items():
        version = _validate_version(version, "policy.versions key")
        validated_versions[version] = _validate_version_record(
            version_record, repository, version, f"policy.versions.{version}"
        )

    return {"repository": repository, "versions": validated_versions}


def _version_record(policy: dict[str, Any], version: str) -> dict[str, Any]:
    versions = policy.get("versions")
    if not isinstance(versions, dict) or version not in versions:
        raise ValueError(f"unknown release version: {version}")
    record = versions[version]
    if not isinstance(record, dict):
        raise ValueError(f"invalid release version record: {version}")
    return record


def resolve_asset(policy: dict[str, Any], version: str, target: str) -> dict[str, str]:
    """Return the validated archive metadata for one release target."""

    if target not in NATIVE_TARGETS:
        raise ValueError(f"unknown native target: {target}")
    record = _version_record(policy, version)
    assets = record.get("assets")
    if not isinstance(assets, dict) or target not in assets:
        raise ValueError(f"release {version} has no asset for target: {target}")
    asset = assets[target]
    if not isinstance(asset, dict):
        raise ValueError(f"invalid asset for release {version}, target {target}")
    return {key: asset[key] for key in ("name", "url", "sha256")}


def resolve_image(policy: dict[str, Any], version: str) -> dict[str, Any]:
    """Return the validated container image metadata for one release."""

    record = _version_record(policy, version)
    image = record.get("image")
    if not isinstance(image, dict):
        raise ValueError(f"release {version} has no image policy")
    return {
        "source": image["source"],
        "index_digest": image["index_digest"],
        "platforms": {
            platform: image["platforms"][platform] for platform in sorted(IMAGE_PLATFORMS)
        },
    }


def _main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("asset", "image"))
    parser.add_argument("policy", type=pathlib.Path)
    parser.add_argument("version")
    parser.add_argument("target", nargs="?")
    args = parser.parse_args(argv)

    try:
        policy = load_policy(args.policy)
        if args.command == "asset":
            if args.target is None:
                raise ValueError("asset command requires TARGET")
            result = resolve_asset(policy, args.version, args.target)
        else:
            if args.target is not None:
                raise ValueError("image command accepts only POLICY and VERSION")
            result = resolve_image(policy, args.version)
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))

    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
