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


def run_in(cwd, command, *, env=None, check=False):
    merged = os.environ.copy()
    merged.update(env or {})
    return subprocess.run(command, cwd=cwd, text=True, capture_output=True, env=merged, check=check)


def extract_step_run(job, step_name):
    ruby = (
        "require 'yaml'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        f"step=data.fetch('jobs').fetch({job!r}).fetch('steps').find " + "{ |s| s['name'] == ARGV[1] }; "
        "abort \"#{ARGV[1]} missing\" unless step; puts step.fetch('run')"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml"), step_name])
    assert_true(result.returncode == 0, result.stderr)
    return result.stdout


def write_script(directory, name, body):
    script = directory / name
    script.write_text("#!/usr/bin/env bash\n" + body, encoding="utf-8")
    script.chmod(0o755)
    return script


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

    descriptor_path = ROOT / "services" / "imgproxy" / "external-release.json"
    descriptor = json.loads(descriptor_path.read_text(encoding="utf-8"))
    assert_true(descriptor["github"]["repository"] == "imgproxy/imgproxy", "imgproxy")
    assert_true(descriptor["github"]["release_tag_template"] == "{version}", "imgproxy")
    assert_true(descriptor["github"]["artifact"] == {"type": "source-tag"}, "imgproxy source-tag descriptor")
    assert_true(descriptor["oci"]["repository"] == "ghcr.io/imgproxy/imgproxy", "imgproxy OCI registry")
    assert_true(descriptor["oci"]["tag_template"] == "{version}", "imgproxy OCI tag")
    assert_true(not (descriptor_path.parent / "upstream-assets.json").exists(), "imgproxy per-version policy")


def test_registry_has_one_canonical_descriptor_path_and_external_defaults_are_off():
    config = json.loads((ROOT / ".github" / "service-release-sources.json").read_text(encoding="utf-8"))
    for service in ("mailpit", "vector", "imgproxy"):
        entry = config["services"][service]
        assert_true(entry.get("external_release_descriptor") in {
            f"services/{service}/external-release.json"
        }, f"missing canonical descriptor path for {service}")
        expected_artifact_source = "external-source" if service == "imgproxy" else "upstream-archive"
        assert_true(entry["artifact_source"] == expected_artifact_source, service)
        assert_true(entry["image_release"] == "mirror", service)
        assert_true(entry["poll"] is (service == "imgproxy"), service)
        if service == "imgproxy":
            assert_true(entry["release_source"] == "github-compose", "imgproxy Compose release source")
            assert_true(entry["image_repository"] == "imgproxy/imgproxy", "imgproxy registry repository")
            assert_true(entry["tag_pattern"] == r"^v[0-9]+\.[0-9]+\.[0-9]+$", "imgproxy exact v tag pattern")
            assert_true(entry["compose_pin"] == {
                "repository": "supabase/storage",
                "ref": "master",
                "path": ".docker/docker-compose-infra.yml",
                "service": "imgproxy",
                "image_repository": "darthsim/imgproxy",
            }, "imgproxy Storage Compose pin")

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
        ("imgproxy", "{}"),
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
    result = run([str(validator), "imgproxy", '{"imgproxy":"v3.8.0"}'])
    assert_true(result.returncode == 0 and result.stdout.strip() == '{"imgproxy":"v3.8.0"}', result.stderr)


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
            (
                "imgproxy",
                "v3.8.0",
                "v3.8.0",
                "ghcr.io/imgproxy/imgproxy",
                "v3.8.0",
                None,
            ),
        ):
            repository = {
                "mailpit": "axllent/mailpit",
                "vector": "vectordotdev/vector",
                "imgproxy": "imgproxy/imgproxy",
            }[service]
            digests = ("a" * 64, "b" * 64, "c" * 64)
            record = {
                "release_tag": release_tag,
                "image": {
                    "source": f"{image_repository}:{image_tag}",
                    "index_digest": "sha256:" + "1" * 64,
                    "platforms": {
                        "linux/amd64": "sha256:" + "2" * 64,
                        "linux/arm64": "sha256:" + "3" * 64,
                    },
                },
            }
            if service == "imgproxy":
                commit = "f" * 40
                record["source"] = {
                    "commit": commit,
                    "url": f"https://github.com/{repository}/archive/{commit}.tar.gz",
                    "sha256": "e" * 64,
                    "fetch_from_github_hash": "sha256-" + "A" * 43 + "=",
                    "vendorHash": "sha256-AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=",
                }
            else:
                record["assets"] = {
                    target: {
                        "name": name,
                        "url": f"https://github.com/{repository}/releases/download/{release_tag}/{name}",
                        "sha256": digest,
                    }
                    for target, name, digest in zip(
                        ("darwin-arm64", "linux-amd64", "linux-arm64"), names, digests
                    )
                }
            snapshots[service] = {
                "repository": repository,
                "versions": {
                    version: {
                        **record,
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
            "printf '%s|%s|%s|%s\\n' \"$1\" \"$2\" \"$3\" \"${4-}\" >> \"$TRACE\"\n"
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
        for service, version in (("mailpit", "v9.9.9"), ("vector", "0.54.0"), ("imgproxy", "v3.8.0")):
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
        assert_true(len(trace_lines) == 3, "resolver was not invoked exactly once per service")
        trace_fields = [line.split("|", 3) for line in trace_lines]
        assert_true(all(len(fields) == 4 for fields in trace_fields), "resolver hook trace is malformed")
        assert_true(all(not fields[3] for fields in trace_fields[:2]), "unexpected lock hook for archive service")
        assert_true(trace_fields[2][3].endswith("services/imgproxy/external-source-lock.sh"), "imgproxy lock hook was not passed to resolver")
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
    assert_true(
        all(service not in parsed["services"] for service in ("mailpit", "vector", "imgproxy")),
        "external service remains in defaults",
    )
    assert_true(parsed["external_versions"] == "{}", "external_versions must default to an explicit empty map")


def test_imgproxy_is_a_manual_release_choice_and_allowlisted():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "input=data.fetch('on').fetch('workflow_dispatch').fetch('inputs').fetch('service'); "
        "puts JSON.generate({options: input.fetch('options'), run: data.fetch('jobs').fetch('plan').fetch('steps').find { |s| s['name'] == 'Validate inputs and check existing release' }.fetch('run')})"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true("imgproxy" in parsed["options"], "imgproxy missing from manual service choice")
    assert_true("imgproxy" in parsed["run"], "imgproxy missing from manual release allowlist")


def test_validation_only_builds_existing_releases_without_publication():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "dispatch=data.fetch('on').fetch('workflow_dispatch').fetch('inputs'); "
        "call=data.fetch('on').fetch('workflow_call').fetch('inputs'); "
        "plan=data.fetch('jobs').fetch('plan'); "
        "plan_step=plan.fetch('steps').find { |s| s['name'] == 'Validate inputs and check existing release' }; "
        "puts JSON.generate({dispatch: dispatch, call: call, outputs: plan.fetch('outputs'), "
        "plan_env: plan_step.fetch('env'), plan_run: plan_step.fetch('run'), "
        "build_if: data.fetch('jobs').fetch('build').fetch('if'), "
        "publish_image_if: data.fetch('jobs').fetch('publish-image').fetch('if'), "
        "publish_release_if: data.fetch('jobs').fetch('publish-release').fetch('if')})"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    for name, inputs in (("workflow_dispatch", parsed["dispatch"]), ("workflow_call", parsed["call"])):
        validation = inputs.get("validation_only")
        assert_true(validation is not None, f"{name} lacks validation_only input")
        assert_true(validation.get("type") == "boolean", f"{name} validation_only must be boolean")
        assert_true(validation.get("default") is False, f"{name} validation_only must default false")
    assert_true("validation_only" in parsed["outputs"], "plan must expose validation_only")
    assert_true("build" in parsed["outputs"], "plan must expose build decision")
    assert_true("VALIDATION_ONLY" in parsed["plan_env"], "plan must receive VALIDATION_ONLY")
    assert_true(parsed["build_if"] == "needs.plan.outputs.build == 'true'", "build must use the decision output")

    for key in ("publish_image_if", "publish_release_if"):
        condition = parsed[key]
        assert_true("needs.plan.outputs.publish == 'true'" in condition, f"{key} lost publication gate")


def test_release_workflow_uses_hotfix_input_and_revision_planner():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "dispatch=data.fetch('on').fetch('workflow_dispatch').fetch('inputs'); "
        "call=data.fetch('on').fetch('workflow_call').fetch('inputs'); "
        "plan=data.fetch('jobs').fetch('plan'); "
        "plan_step=plan.fetch('steps').find { |s| s['name'] == 'Validate inputs and check existing release' }; "
        "puts JSON.generate({dispatch: dispatch, call: call, outputs: plan.fetch('outputs'), "
        "plan_env: plan_step.fetch('env'), plan_run: plan_step.fetch('run')})"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    for name, inputs in (("workflow_dispatch", parsed["dispatch"]), ("workflow_call", parsed["call"])):
        assert_true("force" not in inputs, f"{name} must not have a force input")
        hotfix = inputs.get("hotfix")
        assert_true(hotfix is not None, f"{name} lacks hotfix input")
        assert_true(hotfix.get("type") == "boolean", f"{name} hotfix must be boolean")
        assert_true(hotfix.get("default") is False, f"{name} hotfix must default false")
        hotfix_reason = inputs.get("hotfix_reason")
        assert_true(hotfix_reason is not None, f"{name} lacks hotfix_reason input")
        assert_true(hotfix_reason.get("type") == "string", f"{name} hotfix_reason must be a string")
        assert_true(hotfix_reason.get("default") == "", f"{name} hotfix_reason must default to an empty string")
    assert_true("release_version" in parsed["outputs"], "plan must expose release_version")
    assert_true("revision" in parsed["outputs"], "plan must expose revision")
    assert_true("FORCE" not in parsed["plan_env"], "plan must not reference the removed force input")
    assert_true("HOTFIX" in parsed["plan_env"], "plan must receive HOTFIX")
    assert_true("scripts/plan-release-revision.sh" in parsed["plan_run"], "plan must call the revision planner")
    assert_true(
        "release-workflow-decision.sh" not in parsed["plan_run"],
        "plan must not call the deleted decision helper",
    )


def test_build_step_labels_image_with_release_version():
    # Kept as the one structural check here: nothing executes the workflow's
    # "Build, audit, smoke, and package" step (it needs Docker/Nix), so this
    # is the only place that would notice IMAGE_TAG regressing to the bare
    # upstream version instead of the release version. OCI_VERSION and
    # OCI_REVISION were dropped: they are plain "does this string equal that
    # string" checks with no such gap to cover.
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "s=data.fetch('jobs').fetch('build').fetch('steps').find { |x| x['name'] == 'Build, audit, smoke, and package' }; "
        "abort 'build step missing' unless s; puts JSON.generate(s.fetch('env'))"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    env = json.loads(result.stdout)
    assert_true(
        env.get("IMAGE_TAG")
        == "local/${{ inputs.service }}:${{ needs.plan.outputs.release_version }}-${{ matrix.platform_dir }}",
        f"IMAGE_TAG must be tagged with the release version, got: {env.get('IMAGE_TAG')!r}",
    )


def test_publish_release_is_create_only():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "steps=data.fetch('jobs').fetch('publish-release').fetch('steps'); "
        "puts JSON.generate(steps.map { |s| {name: s['name'], run: s['run']} })"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    steps = json.loads(result.stdout)
    combined_run = "\n".join(step.get("run") or "" for step in steps)
    assert_true("gh release edit" not in combined_run, "publish-release must not edit an existing release")
    assert_true("gh release create" in combined_run, "publish-release must still create the release")
    assert_true(
        any("already exists; revisions are immutable" in (step.get("run") or "") for step in steps),
        "publish-release must fail create-only when a published release tag already exists",
    )


def test_notify_cli_job_runs_once_publish_release_succeeds():
    # gates and wiring: the executable contract (payload, missing-token and
    # failed-dispatch behavior) is covered by the notify_cli_* tests below.
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "job=data.fetch('jobs').fetch('notify-cli'); "
        "abort 'notify-cli step missing' unless job.fetch('steps').any? { |s| s['name'] == 'Notify CLI repository of published release' }; "
        "puts JSON.generate({needs: job.fetch('needs'), if: job.fetch('if')})"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(sorted(parsed["needs"]) == ["plan", "publish-release"], f"notify-cli needs: {parsed['needs']}")
    assert_true(
        parsed["if"] == "needs.plan.outputs.publish == 'true' && needs.publish-release.result == 'success'",
        f"notify-cli must run only after publish-release succeeds: {parsed['if']!r}",
    )


NOTIFY_CLI_ENV = {
    "RELEASE_TAG": "auth-v2.197.0-r0",
    "RELEASE_VERSION": "v2.197.0-r0",
    "REVISION": "0",
    "SERVICE": "auth",
    "VERSION": "v2.197.0",
}


def run_notify_cli(*, token="test-token", gh_script=None):
    run_block = extract_step_run("notify-cli", "Notify CLI repository of published release")
    with tempfile.TemporaryDirectory(prefix="notify-cli-test.") as name:
        directory = pathlib.Path(name)
        script = write_script(directory, "notify.sh", run_block)
        bin_dir = directory / "bin"
        bin_dir.mkdir()
        payload_file = directory / "payload.json"
        default_gh = (
            "#!/bin/sh\n"
            "set -eu\n"
            "cat > \"$FAKE_PAYLOAD_FILE\"\n"
        )
        write_script(bin_dir, "gh", gh_script or default_gh)
        env = dict(NOTIFY_CLI_ENV)
        env["PATH"] = f"{bin_dir}:{os.environ['PATH']}"
        env["FAKE_PAYLOAD_FILE"] = str(payload_file)
        if token is not None:
            env["MIRROR_DISPATCH_TOKEN"] = token
        result = run_in(directory, [str(script)], env=env)
        result.payload = payload_file.read_text(encoding="utf-8") if payload_file.exists() else None
        return result


def test_notify_cli_dispatches_the_published_release_payload():
    result = run_notify_cli()
    assert_true(result.returncode == 0, result.stderr)
    payload = json.loads(result.payload)
    assert_true(payload["event_type"] == "slim-release-published", payload)
    assert_true(
        payload["client_payload"]
        == {
            "service": "auth",
            "upstream_version": "v2.197.0",
            "revision": 0,
            "release_version": "v2.197.0-r0",
        },
        payload,
    )


def test_notify_cli_fails_without_a_dispatch_token():
    result = run_notify_cli(token=None)
    assert_true(result.returncode != 0, "expected a non-zero exit with no dispatch token")
    assert_true("CLI_MIRROR_DISPATCH_TOKEN is not configured" in result.stderr, result.stderr)


def test_notify_cli_fails_when_the_dispatch_call_fails():
    failing_gh = "#!/bin/sh\nset -eu\ncat >/dev/null\nexit 1\n"
    result = run_notify_cli(gh_script=failing_gh)
    assert_true(result.returncode != 0, "expected a non-zero exit when the dispatch call fails")
    assert_true("repository_dispatch of slim-release-published" in result.stderr, result.stderr)


def run_create_release_step(state):
    run_block = extract_step_run("publish-release", "Create GitHub release")
    with tempfile.TemporaryDirectory(prefix="create-release-test.") as name:
        directory = pathlib.Path(name)
        script = write_script(directory, "create.sh", run_block)
        bin_dir = directory / "bin"
        bin_dir.mkdir()
        trace_file = directory / "gh-trace"
        trace_file.write_text("", encoding="utf-8")
        fake_gh = (
            "#!/bin/sh\n"
            "set -eu\n"
            "printf '%s\\n' \"$*\" >> \"$FAKE_GH_TRACE\"\n"
            "case \"$1 $2\" in\n"
            "  'release view')\n"
            "    case \"$FAKE_RELEASE_STATE\" in\n"
            "      missing) printf 'release not found\\n' >&2; exit 1 ;;\n"
            "      draft) printf '{\"isDraft\":true}\\n' ;;\n"
            "      published) printf '{\"isDraft\":false}\\n' ;;\n"
            "    esac\n"
            "    ;;\n"
            "  'release delete') exit 0 ;;\n"
            "  'release create') exit 0 ;;\n"
            "  *) printf 'unexpected gh invocation: %s\\n' \"$*\" >&2; exit 2 ;;\n"
            "esac\n"
        )
        write_script(bin_dir, "gh", fake_gh)
        env = {
            "GH_TOKEN": "test-token",
            "GITHUB_SHA": "0" * 40,
            "RELEASE_TAG": "auth-v2.197.0-r0",
            "RELEASE_VERSION": "v2.197.0-r0",
            "SERVICE": "auth",
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_GH_TRACE": str(trace_file),
            "FAKE_RELEASE_STATE": state,
        }
        result = run_in(directory, [str(script)], env=env)
        result.trace = trace_file.read_text(encoding="utf-8").splitlines()
        return result


def test_create_release_step_creates_when_nothing_exists():
    result = run_create_release_step("missing")
    assert_true(result.returncode == 0, result.stderr)
    assert_true(any(line.startswith("release create ") for line in result.trace), result.trace)
    assert_true(not any(line.startswith("release delete ") for line in result.trace), result.trace)


def test_create_release_step_deletes_a_stale_draft_then_creates():
    result = run_create_release_step("draft")
    assert_true(result.returncode == 0, result.stderr)
    delete_index = next((i for i, line in enumerate(result.trace) if line.startswith("release delete ")), None)
    create_index = next((i for i, line in enumerate(result.trace) if line.startswith("release create ")), None)
    assert_true(delete_index is not None, f"expected a stale draft deletion: {result.trace}")
    assert_true(create_index is not None, f"expected a create after deleting the draft: {result.trace}")
    assert_true(delete_index < create_index, f"draft must be deleted before re-creating: {result.trace}")
    assert_true("--cleanup-tag" not in result.trace[delete_index], "a draft has no tag to clean up")
    assert_true("stale draft" in result.stdout, result.stdout)


def test_create_release_step_fails_when_already_published():
    result = run_create_release_step("published")
    assert_true(result.returncode != 0, "expected a non-zero exit for an already-published release")
    assert_true("already exists; revisions are immutable" in result.stderr, result.stderr)
    assert_true(not any(line.startswith("release delete ") for line in result.trace), result.trace)
    assert_true(not any(line.startswith("release create ") for line in result.trace), result.trace)


def test_stage_release_assets_appends_manifest_hash_to_platform_checksums():
    # The manifest-hashing and re-sort behavior this step performs is
    # exercised end to end in scripts/test-image-artifact-archive.sh, which
    # runs this exact run: block against real fixture files. Only the naming
    # wiring (release assets keyed by RELEASE_VERSION) is checked here.
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "s=data.fetch('jobs').fetch('build').fetch('steps').find { |x| x['name'] == 'Stage release assets' }; "
        "abort 'stage missing' unless s; puts s.fetch('run')"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    run_block = result.stdout
    assert_true(
        "$RELEASE_VERSION" in run_block, "stage step must name release assets with the release version"
    )


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
    assert_true(not service_release_nix.get("if"), "all release targets need Nix for archive packaging")
    assert_true(not service_release_nix_cache.get("if"), "all release targets need the Nix cache")
    source_checkout = next(step for step in release_steps if step.get("name") == "Checkout requested upstream release")
    assert_true("artifact_source == 'source'" in source_checkout.get("if", "") and "external-source" not in source_checkout.get("if", ""), "external-source must not checkout a source tree")

    artifact_nix = next(step for step in artifacts_steps if step.get("name") == "Install Nix")
    assert_true(artifact_nix.get("if") == "steps.artifact-cache.outputs.cache-hit != 'true'", "uncached artifacts need Nix for packaging")
    assert_true("matrix.external != true" not in artifact_nix.get("if", ""), "external artifact source incorrectly skips Nix")
    artifact_nix_cache = next(step for step in artifacts_steps if step.get("name") == "Restore/save Nix store cache")
    assert_true(artifact_nix_cache.get("if") == "steps.artifact-cache.outputs.cache-hit != 'true'", "uncached artifacts need the Nix cache")
    assert_true("matrix.external != true" not in artifact_nix_cache.get("if", ""), "external artifact source incorrectly skips Nix cache")


def test_service_release_mirror_ecr_does_not_gate_publish_release():
    ruby = (
        "require 'yaml'; require 'json'; "
        "data=YAML.safe_load(File.read(ARGV[0]), aliases: true); "
        "jobs=data.fetch('jobs'); "
        "notes=jobs.fetch('publish-release').fetch('steps').find { |s| s['name'] == 'Prepare checksums and release notes' }; "
        "puts JSON.generate({mirror: jobs.key?('mirror-ecr'), natives: jobs.key?('publish-natives'), "
        "mirror_needs: jobs.fetch('mirror-ecr').fetch('needs'), "
        "needs: jobs.fetch('publish-release').fetch('needs'), "
        "publish_if: jobs.fetch('publish-release').fetch('if'), notes_env: notes.fetch('env')})"
    )
    result = run(["ruby", "-e", ruby, str(ROOT / ".github" / "workflows" / "service-release.yml")])
    assert_true(result.returncode == 0, result.stderr)
    parsed = json.loads(result.stdout)
    assert_true(parsed["mirror"] is True, "jobs.mirror-ecr is missing")
    assert_true(parsed["natives"] is True, "jobs.publish-natives is missing")
    assert_true("publish-natives" in parsed["mirror_needs"], "mirror-ecr.needs omits publish-natives")
    assert_true("mirror-ecr" in parsed["needs"], "publish-release.needs omits mirror-ecr")
    publish_if = parsed["publish_if"]
    assert_true("!cancelled()" in publish_if, "publish-release must run past a failed mirror-ecr")
    assert_true("needs.build.result == 'success'" in publish_if, "publish-release must still require build")
    assert_true("needs.publish-image.result == 'success'" in publish_if, "publish-release must still require publish-image")
    assert_true("mirror-ecr" not in publish_if, "mirror-ecr must not gate publish-release")
    assert_true(
        "needs.mirror-ecr.outputs.mirrored" in str(parsed["notes_env"].get("MIRRORED", "")),
        "notes step env omits needs.mirror-ecr.outputs.mirrored",
    )


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
        "bun test ./scripts/ecr-mirror.test.ts ./scripts/publish-native-oci.test.ts",
        "bun build --no-bundle --target=bun",
        "scripts/test-upstream-runtime.sh",
        "scripts/test-nix-release.sh",
        "scripts/test-dockerhub-release.sh",
        "scripts/test-portable-audit.sh",
        "scripts/test-portable-node.sh",
        "scripts/test-portable-beam.sh",
        "scripts/test-portable-postgres.sh",
        "scripts/test-portable-postgrest.sh",
        "scripts/test-studio-artifact.sh",
        "services/analytics/test-seed-ezstd-zstd.sh",
        "scripts/test-license-compliance.sh",
        "scripts/test-poll-service-releases.sh",
        "scripts/test-identity.sh",
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
        merged.update({
            "GITHUB_SHA": "f" * 40,
            "HOTFIX": "false",
            "HOTFIX_REASON": "",
            "IMAGE_RELEASE": "mirror",
            "RELEASE_VERSION": f"{version}-r0",
            "REVISION": "0",
            "SERVICE": service,
            "VERSION": version,
        })
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
