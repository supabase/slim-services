#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT_DIR" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__import__("sys").argv[1])
PLAN = ROOT / "scripts" / "plan-external-release.sh"
VERIFY = ROOT / "scripts" / "verify-external-release.sh"


def run(command, *, env=None, check=False):
    merged = os.environ.copy()
    merged.update(env or {})
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True, env=merged, check=check)


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def test_external_descriptors_are_versionless_and_assets_are_removed():
    for service, repository, release, image, assets in (
        (
            "mailpit",
            "axllent/mailpit",
            "{version}",
            "{version}",
            {
                "darwin-arm64": "mailpit-darwin-arm64.tar.gz",
                "linux-amd64": "mailpit-linux-amd64.tar.gz",
                "linux-arm64": "mailpit-linux-arm64.tar.gz",
            },
        ),
        (
            "vector",
            "vectordotdev/vector",
            "v{version}",
            "{version}-alpine",
            {
                "darwin-arm64": "vector-{version}-arm64-apple-darwin.tar.gz",
                "linux-amd64": "vector-{version}-x86_64-unknown-linux-musl.tar.gz",
                "linux-arm64": "vector-{version}-aarch64-unknown-linux-musl.tar.gz",
            },
        ),
    ):
        descriptor_path = ROOT / "services" / service / "external-release.json"
        assert_true(descriptor_path.is_file(), f"missing descriptor: {descriptor_path}")
        descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
        assert_true(set(descriptor) == {"github", "oci"}, f"descriptor roots changed: {service}")
        assert_true(descriptor["github"]["repository"] == repository, service)
        assert_true(descriptor["github"]["release_tag_template"] == release, service)
        assert_true(descriptor["oci"]["repository"] in {"docker.io/axllent/mailpit", "docker.io/timberio/vector"}, service)
        assert_true(descriptor["oci"]["tag_template"] == image, service)
        targets = descriptor["github"]["artifact"]["targets"]
        assert_true({k: v["name_template"] for k, v in targets.items()} == assets, service)
        assert_true(not (descriptor_path.parent / "upstream-assets.json").exists(), service)


def test_registry_has_one_canonical_descriptor_path_and_external_defaults_are_off():
    config = json.loads((ROOT / ".github" / "service-release-sources.json").read_text(encoding="utf-8"))
    for service in ("mailpit", "vector"):
        entry = config["services"][service]
        assert_true(entry.get("external_release_descriptor") in {
            f"services/{service}/external-release.json"
        }, f"missing canonical descriptor path for {service}")
        assert_true(entry["artifact_source"] == "upstream-archive", service)
        assert_true(entry["image_release"] == "mirror", service)
        assert_true(entry["poll"] is False, service)


def test_poll_validation_rejects_descriptor_dispatch():
    poll = ROOT / "scripts" / "poll-service-releases.sh"
    with tempfile.TemporaryDirectory(prefix="external-poll-test.") as temp:
        config_path = pathlib.Path(temp) / "service-release-sources.json"
        config = json.loads((ROOT / ".github" / "service-release-sources.json").read_text(encoding="utf-8"))
        config["services"]["mailpit"]["poll"] = True
        config_path.write_text(json.dumps(config), encoding="utf-8")
        result = run(
            [str(poll), "--validate-config"],
            env={"SERVICE_RELEASE_CONFIG": str(config_path)},
        )
        assert_true(result.returncode != 0, "descriptor-backed service may not be polled")
        assert_true("poll=false" in result.stderr, result.stderr)


def test_external_versions_planner_rejects_omitted_unused_and_nonexternal_entries():
    validator = ROOT / "scripts" / "validate-external-versions.sh"
    cases = [
        ("mailpit", "{}"),
        ("auth", '{"auth":"v1.2.3"}'),
        ("mailpit", '{"mailpit":"v1.2.3","vector":"0.53.0"}'),
        ("mailpit", '{"mailpit":"1.2.3"}'),
        ("mailpit", '{"mailpit":"v1.2.3","mailpit":"v1.2.4"}'),
    ]
    for services, versions in cases:
        result = run([str(validator), services, versions])
        assert_true(result.returncode != 0, f"invalid external map accepted: {services} {versions}")
    result = run([str(validator), "auth", "{}"])
    assert_true(result.returncode == 0 and result.stdout.strip() == "{}", result.stderr)


def test_plan_resolves_once_and_verifies_offline_snapshot():
    with tempfile.TemporaryDirectory(prefix="external-workflow-test.") as temp:
        temp_path = pathlib.Path(temp)
        trace = temp_path / "trace"
        resolver = temp_path / "resolver"
        snapshots = {}
        for service, version, release_tag, image_repository, image_tag, names in (
            (
                "mailpit",
                "v9.9.9",
                "v9.9.9",
                "docker.io/axllent/mailpit",
                "v9.9.9",
                ("mailpit-darwin-arm64.tar.gz", "mailpit-linux-amd64.tar.gz", "mailpit-linux-arm64.tar.gz"),
            ),
            (
                "vector",
                "0.54.0",
                "v0.54.0",
                "docker.io/timberio/vector",
                "0.54.0-alpine",
                ("vector-0.54.0-arm64-apple-darwin.tar.gz", "vector-0.54.0-x86_64-unknown-linux-musl.tar.gz", "vector-0.54.0-aarch64-unknown-linux-musl.tar.gz"),
            ),
        ):
            repository = "axllent/mailpit" if service == "mailpit" else "vectordotdev/vector"
            digests = ("a" * 64, "b" * 64, "c" * 64)
            snapshots[service] = {
                "repository": repository,
                "versions": {
                    version: {
                        "release_tag": release_tag,
                        "assets": {
                            target: {
                                "name": name,
                                "url": f"https://github.com/{repository}/releases/download/{release_tag}/{name}",
                                "sha256": digest,
                            }
                            for target, name, digest in zip(
                                ("darwin-arm64", "linux-amd64", "linux-arm64"), names, digests
                            )
                        },
                        "image": {
                            "source": f"{image_repository}:{image_tag}",
                            "index_digest": "sha256:" + "1" * 64,
                            "platforms": {
                                "linux/amd64": "sha256:" + "2" * 64,
                                "linux/arm64": "sha256:" + "3" * 64,
                            },
                        },
                    }
                },
            }
        resolver_cases = []
        for service, snapshot in snapshots.items():
            descriptor = str(ROOT / "services" / service / "external-release.json")
            payload = json.dumps(snapshot, separators=(",", ":"))
            resolver_cases.append(
                f'  "{descriptor}") printf "%s\\n" {payload!r} > "$output" ;;\n'
            )
        resolver.write_text(
            "#!/bin/sh\n"
            "printf '%s|%s|%s\\n' \"$1\" \"$2\" \"$3\" >> \"$TRACE\"\n"
            "output=\"$3\"\n"
            "case \"$1\" in\n"
            + "".join(resolver_cases)
            + "  *) printf '%s\\n' 'unknown descriptor' >&2; exit 1 ;;\n"
            "esac\n"
            "python3 - \"$output\" <<'PY' > \"$output.sha256\"\n"
            "import hashlib, pathlib, sys\n"
            "print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())\n"
            "PY\n",
            encoding="utf-8",
        )
        resolver.chmod(0o755)
        outputs = {}
        for service, version in (("mailpit", "v9.9.9"), ("vector", "0.54.0")):
            output = temp_path / f"{service}.json"
            result = run(
                [str(PLAN), service, version, str(output)],
                env={"TRACE": str(trace), "EXTERNAL_RELEASE_RESOLVER": str(resolver)},
            )
            assert_true(result.returncode == 0, result.stderr)
            try:
                metadata = json.loads(result.stdout)
            except json.JSONDecodeError as error:
                raise AssertionError(f"planner stdout must be one JSON document: {result.stdout!r}") from error
            assert_true(metadata["service"] == service and metadata["version"] == version, "planner metadata is incorrect")
            outputs[service] = output
            verified = run([str(VERIFY), str(output), version])
            assert_true(verified.returncode == 0, verified.stderr)
        trace_lines = trace.read_text(encoding="utf-8").splitlines()
        assert_true(len(trace_lines) == 2 and all(line.count("|") == 2 for line in trace_lines), "resolver was not invoked exactly once per service")
        output = outputs["mailpit"]
        output.write_bytes(output.read_bytes() + b"tampered")
        tampered = run([str(VERIFY), str(output), "v9.9.9"])
        assert_true(tampered.returncode != 0, "tampered snapshot accepted")


def test_artifacts_requires_explicit_external_versions_and_no_external_defaults():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "inputs=data.fetch('on').fetch('workflow_dispatch').fetch('inputs'); "
        "puts JSON.generate({services: inputs.fetch('services').fetch('default'), external_versions: inputs.fetch('external_versions').fetch('default')})"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-artifacts.yml")])
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true("mailpit" not in parsed["services"] and "vector" not in parsed["services"], "external service remains in defaults")
    assert_true(parsed["external_versions"] == "{}", "external_versions must default to an explicit empty map")


def test_workflow_downloads_and_verifies_snapshot_before_recipe_build_consumers():
    def workflow_steps(path, job):
        ruby = (
            "require 'yaml'; require 'json'; "
            "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
            "puts JSON.generate(data.fetch('jobs').fetch(ARGV[1]).fetch('steps'))"
        )
        result = run(["ruby", "-e", ruby, str(path), job])
        assert_true(result.returncode == 0, result.stderr)
        return json.loads(result.stdout)

    release_workflow = ROOT / ".github/workflows/service-release.yml"
    release_steps = workflow_steps(release_workflow, "build")
    release_names = [step.get("name", "") for step in release_steps]
    assert_true("Download planned external release snapshot" in release_names, "release build lacks snapshot download")
    assert_true("Verify and export external release snapshot" in release_names, "release build lacks snapshot verification")
    assert_true(release_names.index("Download planned external release snapshot") < release_names.index("Verify and export external release snapshot"), "release verifies before download")
    assert_true(release_names.index("Verify and export external release snapshot") < release_names.index("Build, audit, smoke, and package"), "release verifies too late")
    mirror_steps = workflow_steps(release_workflow, "publish-image")
    mirror_names = [step.get("name", "") for step in mirror_steps]
    assert_true("Download planned external release snapshot for mirror" in mirror_names, "mirror lacks snapshot download")
    assert_true("Verify and export external release snapshot for mirror" in mirror_names, "mirror lacks snapshot verification")
    assert_true(mirror_names.index("Verify and export external release snapshot for mirror") < mirror_names.index("Mirror upstream OCI image"), "mirror verifies too late")
    publish_steps = workflow_steps(release_workflow, "publish-release")
    publish_names = [step.get("name", "") for step in publish_steps]
    assert_true("Checkout packaging repository" in publish_names, "publish-release lacks repository checkout")
    assert_true(publish_names.index("Checkout packaging repository") < publish_names.index("Download and verify planned external release snapshot"), "publish-release verifies before checkout")
    assert_true("Download and verify planned external release snapshot" in publish_names, "publish-release lacks snapshot download/verification")
    assert_true(publish_names.index("Download and verify planned external release snapshot") < publish_names.index("Prepare checksums and release notes"), "publish-release verifies too late")
    artifacts_workflow = ROOT / ".github/workflows/service-artifacts.yml"
    artifacts_steps = workflow_steps(artifacts_workflow, "build")
    artifact_names = [step.get("name", "") for step in artifacts_steps]
    assert_true("Download planned external release snapshots" in artifact_names, "artifact build lacks snapshot download")
    assert_true("Verify and export selected external release snapshot" in artifact_names, "artifact build lacks snapshot verification")
    assert_true(artifact_names.index("Download planned external release snapshots") < artifact_names.index("Verify and export selected external release snapshot"), "artifact verifies before download")
    assert_true(artifact_names.index("Verify and export selected external release snapshot") < artifact_names.index("Prepare target variables"), "artifact verifies after recipe load")
    artifact_verify = next(step for step in artifacts_steps if step.get("name") == "Verify and export selected external release snapshot")
    assert_true("matrix.external" in artifact_verify.get("if", ""), "nonexternal matrix entries must not verify a missing snapshot")

    service_release_nix = next(step for step in release_steps if step.get("name") == "Install Nix")
    service_release_nix_cache = next(step for step in release_steps if step.get("name") == "Restore/save Nix store cache")
    assert_true("external-source" in service_release_nix.get("if", ""), "release build does not install Nix for external-source")
    assert_true("external-source" in service_release_nix_cache.get("if", ""), "release build does not cache Nix for external-source")
    source_checkout = next(step for step in release_steps if step.get("name") == "Checkout requested upstream release")
    assert_true("artifact_source == 'source'" in source_checkout.get("if", "") and "external-source" not in source_checkout.get("if", ""), "external-source must not checkout a source tree")

    artifact_nix = next(step for step in artifacts_steps if step.get("name") == "Install Nix")
    assert_true("steps.vars.outputs.artifact_backend != 'upstream-archive'" in artifact_nix.get("if", ""), "artifact build Nix condition changed")
    assert_true("matrix.external != true" not in artifact_nix.get("if", ""), "external artifact source incorrectly skips Nix")
    artifact_nix_cache = next(step for step in artifacts_steps if step.get("name") == "Restore/save Nix store cache")
    assert_true("steps.vars.outputs.artifact_backend != 'upstream-archive'" in artifact_nix_cache.get("if", ""), "artifact cache Nix condition changed")
    assert_true("matrix.external != true" not in artifact_nix_cache.get("if", ""), "external artifact source incorrectly skips Nix cache")


def test_repository_checks_runs_dynamic_and_external_contracts():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "steps=data.fetch('jobs').fetch('checks').fetch('steps'); "
        "puts JSON.generate(steps.select { |step| step['run'] }.map { |step| step['run'] })"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "repository-checks.yml")])
    assert_true(result.returncode == 0, result.stderr)
    run_blocks = json.loads(result.stdout)
    commands = {
        "scripts/test-external-release.sh",
        "scripts/test-external-workflows.sh",
        "scripts/test-upstream-release.sh",
        "scripts/test-extract-upstream-archive.sh",
        "scripts/test-upstream-artifact.sh",
        "scripts/test-oci-mirror.sh",
        "scripts/test-upstream-runtime.sh",
        "scripts/test-external-source-build.sh",
        "scripts/test-portable-audit.sh",
        "scripts/test-license-compliance.sh",
        "services/vector/test-smoke.sh",
    }
    combined = "\n".join(run_blocks)
    missing = sorted(command for command in commands if command not in combined)
    assert_true(not missing, f"repository checks omit executable tests: {missing}")


def test_release_aggregate_checksums_cover_external_evidence():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "step=data.fetch('jobs').fetch('publish-release').fetch('steps').find { |item| item['name'] == 'Prepare checksums and release notes' }; "
        "puts JSON.generate(step.fetch('run'))"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    run_block = json.loads(result.stdout)
    with tempfile.TemporaryDirectory(prefix="release-checksum-test.") as temp:
        temp_path = pathlib.Path(temp)
        release_assets = temp_path / "release-assets"
        provenance_dir = temp_path / "mirror-provenance"
        release_assets.mkdir()
        provenance_dir.mkdir()
        service = "mailpit"
        version = "v1.31.0"
        platform_files = []
        for platform in ("linux-amd64", "linux-arm64", "darwin-arm64"):
            name = f"{service}-{version}-{platform}.tar.gz"
            path = release_assets / name
            path.write_bytes(f"{platform}\n".encode())
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            (release_assets / f"{service}-{version}-{platform}.SHA256SUMS").write_text(
                f"{digest}  {name}\n", encoding="utf-8"
            )
            platform_files.append(name)
        snapshot = release_assets / f"{service}-{version}.external-release.json"
        snapshot.write_text('{"versions":{"v1.31.0":{}}}\n', encoding="utf-8")
        snapshot_digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
        (release_assets / f"{service}-{version}.external-release.json.sha256").write_text(
            snapshot_digest + "\n", encoding="utf-8"
        )
        provenance = {
            "source_ref": "docker.io/axllent/mailpit:v1.31.0@sha256:" + "a" * 64,
            "pinned_index_digest": "sha256:" + "b" * 64,
            "destination_index_digest": "sha256:" + "c" * 64,
            "platforms": {"linux/amd64": "sha256:" + "d" * 64, "linux/arm64": "sha256:" + "e" * 64},
            "embedded_attestations": [],
        }
        (provenance_dir / "mirror-provenance.json").write_text(json.dumps(provenance), encoding="utf-8")
        (temp_path / "published-image.json").write_text(
            json.dumps({"image": "ghcr.io/supabase/cli/mailpit:v1.31.0", "digest": "sha256:" + "f" * 64}),
            encoding="utf-8",
        )
        merged = os.environ.copy()
        merged.update({"IMAGE_RELEASE": "mirror", "SERVICE": service, "VERSION": version})
        executed = subprocess.run(
            ["bash", "-c", run_block], cwd=temp_path, text=True, capture_output=True, env=merged
        )
        assert_true(executed.returncode == 0, executed.stderr)
        checksum_lines = (release_assets / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
        expected_paths = set(platform_files)
        expected_paths.update(
            {
                f"{service}-{version}.external-release.json",
                f"{service}-{version}.external-release.json.sha256",
                f"{service}-{version}.oci-provenance.json",
            }
        )
        observed = {line.split(None, 1)[1] for line in checksum_lines if line.strip()}
        assert_true(expected_paths <= observed, "aggregate checksums omit release evidence")
        for line in checksum_lines:
            digest, relative_path = line.split(None, 1)
            target = release_assets / relative_path
            assert_true(target.is_file(), f"aggregate checksum references missing file: {relative_path}")
            assert_true(hashlib.sha256(target.read_bytes()).hexdigest() == digest, f"aggregate checksum mismatch: {relative_path}")


def test_service_artifact_persistence_includes_sbom():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "steps=data.fetch('jobs').fetch('build').fetch('steps'); "
        "selected=steps.select { |step| ['Restore identical artifact from cache', 'Save artifact to cache', 'Upload archive + checksums + manifest'].include?(step['name']) }; "
        "puts JSON.generate(selected)"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-artifacts.yml")])
    assert_true(result.returncode == 0, result.stderr)
    steps = json.loads(result.stdout)
    expected = {"Restore identical artifact from cache", "Save artifact to cache", "Upload archive + checksums + manifest"}
    assert_true({step.get("name") for step in steps} == expected, "artifact persistence steps changed unexpectedly")
    for step in steps:
        path = step.get("with", {}).get("path", "")
        assert_true("*.sbom.spdx.json" in path, f"{step['name']} omits the service SBOM")


tests = [value for name, value in globals().items() if name.startswith("test_")]
for test in tests:
    test()
print(f"external workflow integration tests passed ({len(tests)} tests)")
PY
