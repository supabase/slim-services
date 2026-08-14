#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/validate-external-versions.sh "SERVICES" JSON_MAP [CONFIG]

Validate the explicit external_versions map used by service-artifacts and
print its canonical external-service map as compact JSON.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }

services="$1"
versions="$2"
config="${3:-$ROOT_DIR/.github/service-release-sources.json}"

python3 - "$ROOT_DIR" "$config" "$services" "$versions" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as stream:
    registry = json.load(stream).get("services")
if not isinstance(registry, dict):
    raise SystemExit("service registry must contain services")
selected = sys.argv[3].split()


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"external_versions contains duplicate service: {key}")
        result[key] = value
    return result


try:
    versions = json.loads(sys.argv[4], object_pairs_hook=reject_duplicate_keys)
except (json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"external_versions must be valid JSON: {error}") from error
if not isinstance(versions, dict) or any(
    not isinstance(key, str) or not isinstance(value, str) or not value
    for key, value in versions.items()
):
    raise SystemExit("external_versions must map service names to non-empty versions")
selected_set = set(selected)
unknown = sorted(selected_set - set(registry))
if unknown:
    raise SystemExit(f"unknown service(s): {', '.join(unknown)}")
unused = sorted(set(versions) - selected_set)
if unused:
    raise SystemExit(f"external_versions includes unselected services: {', '.join(unused)}")

external = {}
for service in selected:
    entry = registry[service]
    descriptor = entry.get("external_release_descriptor")
    if descriptor:
        if entry.get("artifact_source") not in {"upstream-archive", "external-source"}:
            raise SystemExit(f"external descriptor has unsupported artifact source: {service}")
        if service not in versions:
            raise SystemExit(f"external service requires explicit external_versions entry: {service}")
        pattern = entry.get("tag_pattern")
        if not isinstance(pattern, str) or re.fullmatch(pattern, versions[service]) is None:
            raise SystemExit(f"external version does not match registry tag_pattern for {service}")
        descriptor_path = root / descriptor
        if not descriptor_path.is_file() or descriptor_path.is_symlink():
            raise SystemExit(f"external release descriptor not found: {descriptor_path}")
        external[service] = versions[service]
    elif service in versions:
        raise SystemExit(f"external_versions contains nonexternal service: {service}")
print(json.dumps(external, sort_keys=True, separators=(",", ":")))
PY
