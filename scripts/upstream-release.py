#!/usr/bin/env python3
"""Validate and resolve pinned upstream release assets."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import pathlib
import re
from typing import Any


NATIVE_TARGETS = frozenset({"darwin-arm64", "linux-amd64", "linux-arm64"})
IMAGE_PLATFORMS = frozenset({"linux/amd64", "linux/arm64"})
POLICY_VERSION_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\Z")
RELEASE_TAG_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+/-]{0,127}\Z")
REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
ASSET_NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
OCI_SOURCE_PATTERN = re.compile(
    r"(?P<registry>[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?::[0-9]{1,5})?)/"
    r"(?P<repository>[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*):"
    r"(?P<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})\Z"
)
HEX_DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
IMAGE_DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")


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
    if POLICY_VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError(f"{path} must be a safe snapshot key")
    return version


def _validate_release_tag(value: Any, path: str) -> str:
    value = _require_string(value, path)
    if RELEASE_TAG_PATTERN.fullmatch(value) is None:
        raise ValueError(f"{path} must be a safe release tag")
    return value


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


def _validate_sri(value: Any, path: str) -> str:
    value = _require_string(value, path)
    if not value.startswith("sha256-"):
        raise ValueError(f"{path} must be a sha256 SRI")
    encoded = value.removeprefix("sha256-")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError(f"{path} must be canonical base64") from error
    if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != encoded:
        raise ValueError(f"{path} must encode exactly 32 bytes canonically")
    return value


def _validate_image_digest(value: Any, path: str) -> str:
    value = _require_string(value, path)
    if IMAGE_DIGEST_PATTERN.fullmatch(value) is None:
        raise ValueError(f"{path} must be a sha256: digest")
    return value


def _validate_asset(asset: Any, repository: str, release_tag: str, path: str) -> dict[str, str]:
    asset = _require_dict(asset, path)
    _require_keys(asset, {"name", "url", "sha256"}, path)

    name = _require_string(asset["name"], f"{path}.name")
    if ASSET_NAME_PATTERN.fullmatch(name) is None:
        raise ValueError(f"{path}.name must be a safe archive basename")

    url = _require_string(asset["url"], f"{path}.url")
    expected_url = f"https://github.com/{repository}/releases/download/{release_tag}/{name}"
    if url != expected_url:
        raise ValueError(f"{path}.url must be the canonical GitHub release URL {expected_url!r}")

    sha256 = _validate_archive_digest(asset["sha256"], f"{path}.sha256")
    return {"name": name, "url": url, "sha256": sha256}


def _validate_image(image: Any, path: str) -> dict[str, Any]:
    image = _require_dict(image, path)
    _require_keys(image, {"source", "index_digest", "platforms"}, path)

    source = _require_string(image["source"], f"{path}.source")
    source_match = OCI_SOURCE_PATTERN.fullmatch(source)
    if source_match is None:
        raise ValueError(f"{path}.source must be a canonical tagged registry reference")
    registry = source_match.group("registry")
    if "." not in registry and ":" not in registry and registry != "localhost":
        raise ValueError(f"{path}.source must include an explicit registry")
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


def _validate_source(source: Any, repository: str, path: str) -> dict[str, Any]:
    source = _require_dict(source, path)
    expected = {"commit", "url", "sha256", "fetch_from_github_hash"}
    missing = sorted(expected - set(source))
    if missing:
        raise ValueError(f"{path} missing required keys: {', '.join(missing)}")

    commit = _require_string(source["commit"], f"{path}.commit")
    if COMMIT_PATTERN.fullmatch(commit) is None:
        raise ValueError(f"{path}.commit must be a lowercase full commit SHA-1")
    url = _require_string(source["url"], f"{path}.url")
    expected_url = f"https://github.com/{repository}/archive/{commit}.tar.gz"
    if url != expected_url:
        raise ValueError(f"{path}.url must be the canonical commit archive URL {expected_url!r}")
    sha256 = _validate_archive_digest(source["sha256"], f"{path}.sha256")
    fetch_hash = _require_string(source["fetch_from_github_hash"], f"{path}.fetch_from_github_hash")
    fetch_hash = _validate_sri(fetch_hash, f"{path}.fetch_from_github_hash")

    validated: dict[str, Any] = {
        "commit": commit,
        "url": url,
        "sha256": sha256,
        "fetch_from_github_hash": fetch_hash,
    }
    for key, value in source.items():
        if key in expected:
            continue
        if not isinstance(key, str) or re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", key) is None:
            raise ValueError(f"{path} has an unsafe lock field name: {key!r}")
        if not isinstance(value, str) or not value:
            raise ValueError(f"{path}.{key} must be a non-empty string")
        if key.lower().endswith("hash"):
            value = _validate_sri(value, f"{path}.{key}")
        validated[key] = value
    return validated


def _validate_version_record(version_record: Any, repository: str, version: str, path: str) -> dict[str, Any]:
    version_record = _require_dict(version_record, path)
    expected_keys = {"assets", "source", "image", "release_tag"}
    actual_keys = set(version_record)
    missing = sorted({"image"} - actual_keys)
    unexpected = sorted(actual_keys - expected_keys)
    if missing:
        raise ValueError(f"{path} missing required keys: {', '.join(missing)}")
    if unexpected:
        raise ValueError(f"{path} has unexpected keys: {', '.join(unexpected)}")
    if ("assets" in actual_keys) == ("source" in actual_keys):
        raise ValueError(f"{path} must contain exactly one of assets or source")

    if "release_tag" not in version_record:
        raise ValueError(f"{path} missing required keys: release_tag")
    release_tag = _validate_release_tag(
        version_record["release_tag"], f"{path}.release_tag"
    )

    validated_record: dict[str, Any] = {"release_tag": release_tag}
    if "assets" in actual_keys:
        assets = _require_dict(version_record["assets"], f"{path}.assets")
        _require_keys(assets, set(NATIVE_TARGETS), f"{path}.assets")
        validated_record["assets"] = {
            target: _validate_asset(
                assets[target], repository, release_tag, f"{path}.assets.{target}"
            )
            for target in sorted(NATIVE_TARGETS)
        }
    else:
        validated_record["source"] = _validate_source(
            version_record["source"], repository, f"{path}.source"
        )
    validated_image = _validate_image(
        version_record["image"], f"{path}.image"
    )
    validated_record["image"] = validated_image
    return validated_record


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


def resolve_source(policy: dict[str, Any], version: str) -> dict[str, Any]:
    """Return the validated commit archive metadata for a source release."""

    record = _version_record(policy, version)
    source = record.get("source")
    if not isinstance(source, dict):
        raise ValueError(f"release {version} has no source policy")
    return dict(source)


def resolve_release_tag(policy: dict[str, Any], version: str) -> str:
    """Return the exact upstream GitHub release tag for a canonical version."""

    record = _version_record(policy, version)
    release_tag = record.get("release_tag")
    if not isinstance(release_tag, str):
        raise ValueError(f"release {version} has no GitHub release tag")
    return release_tag


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
    parser.add_argument("command", choices=("asset", "image", "release-tag", "source"))
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
        elif args.command == "image":
            if args.target is not None:
                raise ValueError("image command accepts only POLICY and VERSION")
            result = resolve_image(policy, args.version)
        elif args.command == "release-tag":
            if args.target is not None:
                raise ValueError("release-tag command accepts only POLICY and VERSION")
            result = resolve_release_tag(policy, args.version)
        else:
            if args.target is not None:
                raise ValueError("source command accepts only POLICY and VERSION")
            result = resolve_source(policy, args.version)
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))

    if args.command == "release-tag":
        print(result)
    else:
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
