#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/plan-external-release.sh SERVICE VERSION OUTPUT [CONFIG]

Validate an external service registry entry, resolve its versionless descriptor
once, and verify the resulting immutable snapshot before returning metadata.
The resolver may be overridden with EXTERNAL_RELEASE_RESOLVER for controlled
tests; production uses scripts/resolve-external-release.sh.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 3 && $# -le 4 ]] || { usage >&2; exit 2; }

service="$1"
version="$2"
output="$3"
config="${4:-$ROOT_DIR/.github/service-release-sources.json}"

descriptor=""
metadata=""
lock_script=""
metadata_tmp="$(mktemp "${TMPDIR:-/tmp}/external-plan.XXXXXX")"
trap 'rm -f "$metadata_tmp"' EXIT
python3 - "$ROOT_DIR" "$config" "$service" "$version" "$output" >"$metadata_tmp" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
config_path = pathlib.Path(sys.argv[2])
service = sys.argv[3]
version = sys.argv[4]
output = pathlib.Path(sys.argv[5]).resolve()
with config_path.open(encoding="utf-8") as stream:
    config = json.load(stream)
services = config.get("services")
if not isinstance(services, dict) or service not in services:
    raise SystemExit(f"release policy not found for {service}")
entry = services[service]
if not isinstance(entry, dict):
    raise SystemExit(f"release policy for {service} must be an object")
path = entry.get("external_release_descriptor")
if not isinstance(path, str) or not path:
    raise SystemExit(f"external release descriptor is required for {service}")
if entry.get("artifact_source") not in {"upstream-archive", "external-source"}:
    raise SystemExit(f"external descriptor has unsupported artifact source for {service}")
pattern = entry.get("tag_pattern")
if not isinstance(pattern, str) or not pattern.startswith("^") or not pattern.endswith("$"):
    raise SystemExit(f"tag_pattern must be anchored for {service}")
try:
    compiled = re.compile(pattern)
except re.error as error:
    raise SystemExit(f"invalid tag_pattern for {service}: {error}") from error
if compiled.fullmatch(version) is None:
    raise SystemExit(f"version is not an allowed release tag for {service}: {version} (expected {pattern})")
descriptor_path = root / path
if not descriptor_path.is_file() or descriptor_path.is_symlink():
    raise SystemExit(f"external release descriptor not found: {descriptor_path}")

# Recipes may require the workflow snapshot environment while being loaded.
# The placeholder is never consumed by the resolver and is replaced by the
# generated output path in workflow consumers.
env = dict(os.environ)
env.update({"UPSTREAM_ASSETS_FILE": str(output), "TARGET_OS": "linux", "ARCH": "amd64"})
try:
    result = subprocess.run(
        [
            "bash",
            "-c",
            "set -euo pipefail; source scripts/lib.sh; load_recipe \"$1\" >/dev/null; printf \"%s\" \"${EXTERNAL_SOURCE_LOCK_SCRIPT:-}\"",
            "_",
            service,
        ],
        cwd=root,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
except subprocess.CalledProcessError as error:
    raise SystemExit(error.stderr.strip() or f"could not load recipe for {service}") from error
lock = result.stdout.strip()
if lock:
    lock_path = pathlib.Path(lock)
    if not lock_path.is_absolute():
        lock_path = root / lock_path
    if not lock_path.is_file() or lock_path.is_symlink():
        raise SystemExit(f"external source lock script not found: {lock_path}")
    lock = str(lock_path)
metadata = {
    "service": service,
    "version": version,
    "descriptor": str(descriptor_path),
}
print(str(descriptor_path), json.dumps(metadata, sort_keys=True, separators=(",", ":")), lock, sep="\t")
PY
IFS=$'\t' read -r descriptor metadata lock_script <"$metadata_tmp"

resolver="${EXTERNAL_RELEASE_RESOLVER:-$ROOT_DIR/scripts/resolve-external-release.sh}"
[[ -x "$resolver" ]] || { printf 'external resolver is not executable: %s\n' "$resolver" >&2; exit 1; }
command=("$resolver" "$descriptor" "$version" "$output")
if [[ -n "$lock_script" ]]; then
  command+=("$lock_script")
fi
"${command[@]}"
"$ROOT_DIR/scripts/verify-external-release.sh" "$output" "$version"

python3 - "$output" "$metadata" <<'PY'
import json
import pathlib
import sys

snapshot_path = pathlib.Path(sys.argv[1])
metadata = json.loads(sys.argv[2])
with snapshot_path.open(encoding="utf-8") as stream:
    snapshot = json.load(stream)
version = metadata["version"]
record = snapshot["versions"][version]
result = {
    **metadata,
    "repository": snapshot["repository"],
    "release_tag": record["release_tag"],
    "source_commit": record.get("source", {}).get("commit", ""),
}
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
