#!/usr/bin/env python3
"""Resolve a versionless external-release descriptor into an immutable policy."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from typing import Any


REPOSITORY_PATTERN = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
SHA1_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
IMAGE_DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}\Z")
SAFE_KEY_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\Z")
SAFE_TAG_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+/-]{0,127}\Z")
OCI_TAG_PATTERN = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\Z")
OCI_REPOSITORY_PATTERN = re.compile(
    r"(?P<registry>[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?::[0-9]{1,5})?)/"
    r"(?P<repository>[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*)\Z"
)
ASSET_NAME_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
TEMPLATE_PATTERN = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
REQUIRED_PLATFORMS = ("linux/amd64", "linux/arm64")
NATIVE_TARGETS = ("darwin-arm64", "linux-amd64", "linux-arm64")
MAX_TAG_DEPTH = 16


class ResolverError(ValueError):
    """A descriptor or authoritative upstream response failed validation."""


def _require_dict(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ResolverError(f"{path} must be an object")
    return value


def _require_string(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value:
        raise ResolverError(f"{path} must be a non-empty string")
    return value


def _require_exact_keys(value: dict[str, Any], expected: set[str], path: str) -> None:
    missing = sorted(expected - set(value))
    unexpected = sorted(set(value) - expected)
    if missing:
        raise ResolverError(f"{path} missing required keys: {', '.join(missing)}")
    if unexpected:
        raise ResolverError(f"{path} has unexpected keys: {', '.join(unexpected)}")


def _validate_repository(value: Any, path: str) -> str:
    repository = _require_string(value, path)
    if REPOSITORY_PATTERN.fullmatch(repository) is None:
        raise ResolverError(f"{path} must be an owner/name repository")
    return repository


def _validate_oci_repository(value: Any, path: str) -> str:
    repository = _require_string(value, path)
    match = OCI_REPOSITORY_PATTERN.fullmatch(repository)
    if match is None:
        raise ResolverError(f"{path} must include an explicit registry and repository")
    registry = match.group("registry")
    if "." not in registry and ":" not in registry and registry != "localhost":
        raise ResolverError(f"{path} must include an explicit registry")
    return repository


def _validate_template(value: Any, path: str) -> str:
    template = _require_string(value, path)
    fields = TEMPLATE_PATTERN.findall(template)
    if any(field != "version" for field in fields) or fields.count("version") > 1:
        raise ResolverError(f"{path} may contain only one {{version}} substitution")
    return template


def _validate_sri(value: Any, path: str) -> str:
    value = _require_string(value, path)
    if not value.startswith("sha256-"):
        raise ResolverError(f"{path} must be a sha256 SRI")
    encoded = value.removeprefix("sha256-")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ResolverError(f"{path} must be canonical base64") from error
    if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != encoded:
        raise ResolverError(f"{path} must encode exactly 32 bytes canonically")
    return value


def _expand(template: str, version: str, path: str) -> str:
    _validate_template(template, path)
    return template.replace("{version}", version)


def _run_json(command: list[str], *, input_bytes: bytes | None = None) -> Any:
    try:
        result = subprocess.run(
            command,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            detail = error.stderr.decode(errors="replace").strip()
            raise ResolverError(
                f"command failed ({' '.join(command)}): {detail or error.returncode}"
            ) from error
        raise ResolverError(f"could not execute {' '.join(command)}: {error}") from error
    try:
        return json.loads(result.stdout.decode())
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ResolverError(f"command returned malformed JSON: {' '.join(command)}") from error


def _run_output(command: list[str]) -> str:
    try:
        result = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True
        )
    except (OSError, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            detail = error.stderr.decode(errors="replace").strip()
            raise ResolverError(
                f"command failed ({' '.join(command)}): {detail or error.returncode}"
            ) from error
        raise ResolverError(f"could not execute {' '.join(command)}: {error}") from error
    try:
        return result.stdout.decode()
    except UnicodeDecodeError as error:
        raise ResolverError(f"command returned non-UTF-8 output: {' '.join(command)}") from error


def _validate_descriptor(raw: Any) -> dict[str, Any]:
    descriptor = _require_dict(raw, "descriptor")
    _require_exact_keys(descriptor, {"github", "oci"}, "descriptor")
    github = _require_dict(descriptor["github"], "descriptor.github")
    _require_exact_keys(
        github, {"repository", "release_tag_template", "artifact"}, "descriptor.github"
    )
    repository = _validate_repository(github["repository"], "descriptor.github.repository")
    release_tag_template = _validate_template(
        github["release_tag_template"], "descriptor.github.release_tag_template"
    )

    artifact_raw = github["artifact"]
    artifact_type: str
    artifact: dict[str, Any]
    if isinstance(artifact_raw, str):
        raise ResolverError("descriptor.github.artifact must be an object")
    artifact = _require_dict(artifact_raw, "descriptor.github.artifact")
    artifact_type = artifact.get("type")
    if not isinstance(artifact_type, str):
        raise ResolverError("descriptor.github.artifact.type must be a string")
    if artifact_type not in {"release-assets", "source-tag"}:
        raise ResolverError(
            "descriptor.github.artifact.type must be release-assets or source-tag"
        )

    normalized_targets: dict[str, str] = {}
    if artifact_type == "release-assets":
        _require_exact_keys(artifact, {"type", "targets"}, "descriptor.github.artifact")
        targets = artifact["targets"]
        targets = _require_dict(targets, "descriptor.github.artifact.targets")
        if set(targets) != set(NATIVE_TARGETS) or len(targets) != len(NATIVE_TARGETS):
            raise ResolverError(
                "descriptor.github.artifact.targets must contain darwin-arm64, linux-amd64, and linux-arm64 exactly once"
            )
        for target, raw_target in targets.items():
            if not isinstance(target, str) or not target:
                raise ResolverError("descriptor.github.artifact.targets keys must be strings")
            if isinstance(raw_target, str):
                template = raw_target
            else:
                target_object = _require_dict(
                    raw_target, f"descriptor.github.artifact.targets.{target}"
                )
                _require_exact_keys(
                    target_object,
                    {"name_template"},
                    f"descriptor.github.artifact.targets.{target}",
                )
                template = target_object["name_template"]
            template = _validate_template(
                template, f"descriptor.github.artifact.targets.{target}"
            )
            normalized_targets[target] = template
    else:
        _require_exact_keys(artifact, {"type"}, "descriptor.github.artifact")

    oci = _require_dict(descriptor["oci"], "descriptor.oci")
    _require_exact_keys(oci, {"repository", "tag_template", "required_platforms"}, "descriptor.oci")
    oci_repository = _validate_oci_repository(oci["repository"], "descriptor.oci.repository")
    oci_tag_template = _validate_template(oci["tag_template"], "descriptor.oci.tag_template")
    required_platforms = oci["required_platforms"]
    if not isinstance(required_platforms, list) or any(not isinstance(item, str) for item in required_platforms):
        raise ResolverError("descriptor.oci.required_platforms must be an array of strings")
    if set(required_platforms) != set(REQUIRED_PLATFORMS) or len(required_platforms) != len(REQUIRED_PLATFORMS):
        raise ResolverError("descriptor.oci.required_platforms must contain linux/amd64 and linux/arm64 exactly once")

    return {
        "github_repository": repository,
        "release_tag_template": release_tag_template,
        "artifact_type": artifact_type,
        "asset_templates": normalized_targets,
        "oci_repository": oci_repository,
        "oci_tag_template": oci_tag_template,
    }


def _release(repository: str, release_tag: str) -> dict[str, Any]:
    raw = _run_json(["gh", "api", f"repos/{repository}/releases/tags/{release_tag}"])
    release = _require_dict(raw, "GitHub release")
    if release.get("tag_name") != release_tag:
        raise ResolverError(f"GitHub release tag is not exact: expected {release_tag}")
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise ResolverError(f"GitHub release {release_tag} must be published and stable")
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ResolverError("GitHub release assets must be an array")
    return release


def _resolve_commit(repository: str, release_tag: str) -> str:
    ref = _run_json(["gh", "api", f"repos/{repository}/git/ref/tags/{release_tag}"])
    ref_object = _require_dict(_require_dict(ref, "Git tag ref").get("object"), "Git tag ref.object")
    current_type = ref_object.get("type")
    current_sha = _require_string(ref_object.get("sha"), "Git tag ref.object.sha")
    seen: set[str] = set()
    for _ in range(MAX_TAG_DEPTH):
        if current_sha in seen:
            raise ResolverError("Git tag object cycle detected")
        seen.add(current_sha)
        if current_type == "commit":
            if SHA1_PATTERN.fullmatch(current_sha) is None:
                raise ResolverError("Git tag commit target is not a full SHA-1")
            return current_sha
        if current_type != "tag" or SHA1_PATTERN.fullmatch(current_sha) is None:
            raise ResolverError("Git tag must resolve to a commit or annotated tag object")
        tag = _run_json(["gh", "api", f"repos/{repository}/git/tags/{current_sha}"])
        tag_object = _require_dict(_require_dict(tag, "Git tag object").get("object"), "Git tag object.object")
        current_type = tag_object.get("type")
        current_sha = _require_string(tag_object.get("sha"), "Git tag object.object.sha")
    raise ResolverError("Git tag object chain exceeds maximum depth")


def _asset_map(
    release: dict[str, Any],
    templates: dict[str, str],
    repository: str,
    release_tag: str,
    version: str,
) -> dict[str, Any]:
    assets = release["assets"]
    result: dict[str, Any] = {}
    for target, template in sorted(templates.items()):
        name = _expand(template, version, f"asset template {target}")
        if ASSET_NAME_PATTERN.fullmatch(name) is None:
            raise ResolverError(f"asset template {target} expands to an unsafe asset name")
        matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == name]
        if len(matches) != 1:
            raise ResolverError(f"GitHub release asset {name!r} must exist exactly once")
        asset = _require_dict(matches[0], f"GitHub release asset {name}")
        if asset.get("state") != "uploaded":
            raise ResolverError(f"GitHub release asset {name!r} is not uploaded")
        browser_url = asset.get("browser_download_url")
        expected_url = f"https://github.com/{repository}/releases/download/{release_tag}/{name}"
        if browser_url != expected_url:
            raise ResolverError(f"GitHub release asset {name!r} has a noncanonical download URL")
        digest = asset.get("digest")
        if not isinstance(digest, str) or IMAGE_DIGEST_PATTERN.fullmatch(digest) is None:
            raise ResolverError(f"GitHub release asset {name!r} is missing an authoritative sha256 digest")
        result[target] = {"name": name, "url": expected_url, "sha256": digest.removeprefix("sha256:")}
    return result


def _download_archive(url: str) -> str:
    with tempfile.NamedTemporaryFile(prefix="external-release-", suffix=".tar.gz", delete=False) as stream:
        path = stream.name
    try:
        try:
            subprocess.run(["curl", "-fsSL", url, "-o", path], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except (OSError, subprocess.CalledProcessError) as error:
            if isinstance(error, subprocess.CalledProcessError):
                detail = error.stderr.decode(errors="replace").strip()
                raise ResolverError(f"curl failed: {detail or error.returncode}") from error
            raise ResolverError(f"could not execute curl: {error}") from error
        return path
    except Exception:
        pathlib.Path(path).unlink(missing_ok=True)
        raise


def _source_record(
    repository: str,
    release_tag: str,
    lock_script: pathlib.Path | None,
) -> dict[str, Any]:
    commit = _resolve_commit(repository, release_tag)
    url = f"https://github.com/{repository}/archive/{commit}.tar.gz"
    archive_path = _download_archive(url)
    try:
        digest = hashlib.sha256(pathlib.Path(archive_path).read_bytes()).hexdigest()
        nix_raw = _run_json(
            [
                "nix",
                "store",
                "prefetch-file",
                "--json",
                "--unpack",
                pathlib.Path(archive_path).resolve().as_uri(),
            ]
        )
        nix_result = _require_dict(nix_raw, "nix prefetch result")
        fetch_hash = nix_result.get("hash")
        fetch_hash = _validate_sri(fetch_hash, "nix prefetch result hash")
    finally:
        pathlib.Path(archive_path).unlink(missing_ok=True)
    source: dict[str, Any] = {
        "commit": commit,
        "url": url,
        "sha256": digest,
        "fetch_from_github_hash": fetch_hash,
    }
    if lock_script is not None:
        command = [str(lock_script)]
        if not os.access(lock_script, os.X_OK):
            command = ["/bin/sh", str(lock_script)]
        lock_raw = _run_json(
            command,
            input_bytes=(json.dumps(source, sort_keys=True, separators=(",", ":")) + "\n").encode(),
        )
        lock = _require_dict(lock_raw, "source lock hook output")
        if not lock:
            raise ResolverError("source lock hook output must not be empty")
        for key, value in lock.items():
            if not isinstance(key, str) or re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", key) is None:
                raise ResolverError("source lock hook returned an unsafe field name")
            if key in source:
                raise ResolverError(f"source lock hook may not override source field {key}")
            if not isinstance(value, str) or not value:
                raise ResolverError(f"source lock hook field {key} must be a non-empty string")
            if key.lower().endswith("hash"):
                value = _validate_sri(value, f"source lock hook field {key}")
            source[key] = value
    return source


def _image_record(repository: str, tag: str) -> dict[str, Any]:
    if OCI_TAG_PATTERN.fullmatch(tag) is None:
        raise ResolverError("expanded OCI tag is not a safe OCI tag")
    source = f"{repository}:{tag}"
    digest_raw = _run_output(["regctl", "image", "digest", source]).strip()
    if IMAGE_DIGEST_PATTERN.fullmatch(digest_raw) is None:
        raise ResolverError("regctl returned a malformed OCI index digest")
    manifest_raw = _run_output(["regctl", "image", "manifest", "--format", "raw-body", f"{source}@{digest_raw}"])
    try:
        manifest = json.loads(manifest_raw)
    except json.JSONDecodeError as error:
        raise ResolverError("regctl returned a malformed OCI index") from error
    manifest = _require_dict(manifest, "OCI manifest")
    media_type = manifest.get("mediaType")
    if media_type not in {
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
    }:
        raise ResolverError("OCI source must resolve to an image index or Docker manifest list")
    if not isinstance(manifest.get("schemaVersion"), int) or isinstance(manifest["schemaVersion"], bool) or manifest["schemaVersion"] != 2:
        raise ResolverError("OCI source must use schemaVersion 2")
    expected_child_media_type = (
        "application/vnd.oci.image.manifest.v1+json"
        if media_type == "application/vnd.oci.image.index.v1+json"
        else "application/vnd.docker.distribution.manifest.v2+json"
    )
    manifests = manifest.get("manifests")
    if not isinstance(manifests, list):
        raise ResolverError("OCI index manifests must be an array")
    platforms: dict[str, str] = {}
    for descriptor in manifests:
        descriptor = _require_dict(descriptor, "OCI platform descriptor")
        platform = _require_dict(descriptor.get("platform"), "OCI platform descriptor.platform")
        os_name = platform.get("os")
        architecture = platform.get("architecture")
        if not isinstance(os_name, str) or not isinstance(architecture, str):
            raise ResolverError("OCI platform descriptor is missing os/architecture")
        name = f"{os_name}/{architecture}"
        if name in platforms:
            raise ResolverError(f"OCI index contains duplicate platform {name}")
        descriptor_digest = descriptor.get("digest")
        if name in REQUIRED_PLATFORMS:
            if descriptor.get("mediaType") != expected_child_media_type:
                raise ResolverError(
                    f"OCI platform {name} has an invalid image manifest media type"
                )
            if not isinstance(descriptor_digest, str) or IMAGE_DIGEST_PATTERN.fullmatch(descriptor_digest) is None:
                raise ResolverError(f"OCI platform {name} has a malformed digest")
            platforms[name] = descriptor_digest
    missing = [platform for platform in REQUIRED_PLATFORMS if platform not in platforms]
    if missing:
        raise ResolverError(f"OCI index is missing required platform(s): {', '.join(missing)}")
    return {"source": source, "index_digest": digest_raw, "platforms": {platform: platforms[platform] for platform in REQUIRED_PLATFORMS}}


def resolve(descriptor_path: pathlib.Path, version: str, lock_script: pathlib.Path | None = None) -> dict[str, Any]:
    try:
        with descriptor_path.open(encoding="utf-8") as stream:
            descriptor_raw = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        raise ResolverError(f"could not read descriptor: {error}") from error
    descriptor = _validate_descriptor(descriptor_raw)
    if SAFE_KEY_PATTERN.fullmatch(version) is None:
        raise ResolverError(f"version is not a safe snapshot key: {version}")
    release_tag = _expand(descriptor["release_tag_template"], version, "descriptor.github.release_tag_template")
    if SAFE_TAG_PATTERN.fullmatch(release_tag) is None:
        raise ResolverError("expanded release tag is not a safe tag")
    release = _release(descriptor["github_repository"], release_tag)
    record: dict[str, Any] = {"release_tag": release_tag}
    if descriptor["artifact_type"] == "release-assets":
        record["assets"] = _asset_map(
            release,
            descriptor["asset_templates"],
            descriptor["github_repository"],
            release_tag,
            version,
        )
    else:
        record["source"] = _source_record(
            descriptor["github_repository"], release_tag, lock_script
        )
    image_tag = _expand(descriptor["oci_tag_template"], version, "descriptor.oci.tag_template")
    record["image"] = _image_record(descriptor["oci_repository"], image_tag)
    return {"repository": descriptor["github_repository"], "versions": {version: record}}


def write_snapshot(snapshot: dict[str, Any], output_path: pathlib.Path) -> None:
    encoded = (json.dumps(snapshot, sort_keys=True, separators=(",", ":")) + "\n").encode()
    digest = hashlib.sha256(encoded).hexdigest()
    sidecar_path = output_path.with_name(output_path.name + ".sha256")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_paths: list[pathlib.Path] = []
    try:
        for destination, data in (
            (output_path, encoded),
            (sidecar_path, (digest + "\n").encode()),
        ):
            with tempfile.NamedTemporaryFile(
                mode="wb",
                dir=destination.parent,
                prefix=f".{destination.name}.",
                suffix=".tmp",
                delete=False,
            ) as stream:
                temporary = pathlib.Path(stream.name)
                temporary_paths.append(temporary)
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        os.replace(temporary_paths[0], output_path)
        temporary_paths.pop(0)
        os.replace(temporary_paths[0], sidecar_path)
        temporary_paths.pop(0)
    finally:
        for temporary in temporary_paths:
            temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("descriptor", type=pathlib.Path)
    parser.add_argument("version")
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("source_lock_script", nargs="?", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        snapshot = resolve(args.descriptor, args.version, args.source_lock_script)
        write_snapshot(snapshot, args.output)
    except (OSError, ResolverError, TypeError, json.JSONDecodeError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
