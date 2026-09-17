#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/ecr-mirror.sh payload SERVICE VERSION DIGEST
  scripts/ecr-mirror.sh request SERVICE VERSION DIGEST
  scripts/ecr-mirror.sh verify SERVICE VERSION DIGEST
  scripts/ecr-mirror.sh sync [--request]

Mirror published slim images and native OCI tags to AWS ECR Public through
the mirror workflow hosted in the dispatch repository (supabase/cli by
default). Always dispatch: an unchanged image digest must not skip the
request, because native tags may have moved. Never prune untagged
manifests; already-shipped CLIs still pin those digests.

Subcommands:
  payload  Print the repository_dispatch request body for one release.
           When NATIVE_ARTIFACTS_FILE is set, include natives[].
  request  Send the repository_dispatch event, then poll the destination
           image tag until its index digest matches DIGEST. Native copy
           is best-effort on the receiver and does not gate this verify.
  verify   Poll the destination until its index digest matches DIGEST.
  sync     Compare every published release (image and native tags) against
           the destination registry and report drift. With --request, also
           dispatch a mirror request for each missing or mismatched tag
           and verify the image digest. Exits non-zero while any tag is
           out of sync.

Environment:
  MIRROR_DISPATCH_TOKEN     Token used to send repository_dispatch
                            (required by request, and by sync --request).
  MIRROR_DISPATCH_REPO      Dispatch repository (default: supabase/cli).
  MIRROR_EVENT_TYPE         Dispatch event type (default: mirror-slim-image).
  SOURCE_IMAGE_PREFIX       Source repository prefix
                            (default: ghcr.io/supabase/cli).
  ECR_MIRROR_PREFIX         Destination repository prefix
                            (default: public.ecr.aws/supabase/cli).
  ECR_MIRROR_TIMEOUT        Verify timeout in seconds (default: 900).
  ECR_MIRROR_POLL_INTERVAL  Verify poll interval in seconds (default: 30).
  NATIVE_ARTIFACTS_FILE     JSON array of {tag,digest} native OCI artifacts
                            to include in the dispatch payload.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 ]] || { usage >&2; exit 2; }

require_cmd python3

CONFIG_FILE="${SERVICE_RELEASE_CONFIG:-$ROOT_DIR/.github/service-release-sources.json}"
MIRROR_DISPATCH_REPO="${MIRROR_DISPATCH_REPO:-supabase/cli}"
MIRROR_EVENT_TYPE="${MIRROR_EVENT_TYPE:-mirror-slim-image}"
SOURCE_IMAGE_PREFIX="${SOURCE_IMAGE_PREFIX:-ghcr.io/supabase/cli}"
ECR_MIRROR_PREFIX="${ECR_MIRROR_PREFIX:-public.ecr.aws/supabase/cli}"
ECR_MIRROR_TIMEOUT="${ECR_MIRROR_TIMEOUT:-900}"
ECR_MIRROR_POLL_INTERVAL="${ECR_MIRROR_POLL_INTERVAL:-30}"
NATIVE_TARGETS=(linux-arm64 linux-amd64 darwin-arm64)
# Dest lookups must succeed without the caller's registry credentials.
anonymous_regctl_config=""
anonymous_docker_config=""

[[ -f "$CONFIG_FILE" ]] || fail "service release config not found: $CONFIG_FILE"

validate_release() {
  local service="$1" version="$2"
  python3 - "$CONFIG_FILE" "$service" "$version" <<'PY' || exit 1
import json
import re
import sys

config_path, service, version = sys.argv[1:]
with open(config_path, encoding="utf-8") as fh:
    services = json.load(fh)["services"]
config = services.get(service)
if config is None:
    raise SystemExit(f"unknown release service: {service}")
if not re.fullmatch(config["tag_pattern"], version):
    raise SystemExit(f"version is not an allowed release tag for {service}: {version}")
PY
}

validate_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "not a sha256 image digest: $1"
}

render_payload() {
  local service="$1" version="$2" digest="$3"
  python3 - "$MIRROR_EVENT_TYPE" "$service" "$version" \
    "$SOURCE_IMAGE_PREFIX/$service:$version" "$digest" \
    "$ECR_MIRROR_PREFIX/$service:$version" \
    "${NATIVE_ARTIFACTS_FILE:-}" <<'PY'
import json
import os
import re
import sys

event_type, service, version, source, digest, destination, natives_path = sys.argv[1:]
payload = {
    "event_type": event_type,
    "client_payload": {
        "service": service,
        "version": version,
        "source": source,
        "digest": digest,
        "destination": destination,
    },
}
if natives_path:
    with open(natives_path, encoding="utf-8") as fh:
        natives = json.load(fh)
    if not isinstance(natives, list):
        raise SystemExit("natives must be a JSON array")
    tag_re = re.compile(
        rf"^{re.escape(version)}-native-(linux-arm64|linux-amd64|darwin-arm64)$"
    )
    digest_re = re.compile(r"^sha256:[0-9a-f]{64}$")
    cleaned = []
    for item in natives:
        if not isinstance(item, dict) or "tag" not in item or "digest" not in item:
            raise SystemExit(f"invalid native entry: {item!r}")
        if not tag_re.fullmatch(item["tag"]):
            raise SystemExit(
                f"native tag does not match {version}-native-<target>: {item['tag']}"
            )
        if not digest_re.fullmatch(item["digest"]):
            raise SystemExit(f"not a sha256 native digest: {item['digest']}")
        cleaned.append({"tag": item["tag"], "digest": item["digest"]})
    payload["client_payload"]["natives"] = cleaned
print(json.dumps(payload, indent=2, sort_keys=True))
PY
}

init_anonymous_configs() {
  if [[ -z "$anonymous_regctl_config" ]]; then
    anonymous_regctl_config="$(mktemp -d "${TMPDIR:-/tmp}/slim-ecr-anon-regctl.XXXXXX")"
    anonymous_docker_config="$(mktemp -d "${TMPDIR:-/tmp}/slim-ecr-anon-docker.XXXXXX")"
  fi
}

destination_digest() {
  local reference="$1"
  REGCTL_CONFIG="$anonymous_regctl_config" \
  DOCKER_CONFIG="$anonymous_docker_config" \
    regctl image digest "$reference" 2>/dev/null | tr -d '[:space:]' || true
}

verify_release() {
  local service="$1" version="$2" digest="$3"
  init_anonymous_configs
  local destination_ref="$ECR_MIRROR_PREFIX/$service:$version"
  local deadline=$((SECONDS + ECR_MIRROR_TIMEOUT))
  local live=""
  while true; do
    live="$(destination_digest "$destination_ref")"
    if [[ "$live" == "$digest" ]]; then
      log "verified $destination_ref@$digest"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      fail "destination did not match within ${ECR_MIRROR_TIMEOUT}s: $destination_ref (expected $digest, got ${live:-none})"
    fi
    log "waiting for $destination_ref (expected $digest, got ${live:-none})"
    sleep "$ECR_MIRROR_POLL_INTERVAL"
  done
}

request_release() {
  local service="$1" version="$2" digest="$3"
  init_anonymous_configs
  [[ -n "${MIRROR_DISPATCH_TOKEN:-}" ]] || fail "MIRROR_DISPATCH_TOKEN is required to send repository_dispatch"
  log "requesting mirror of $SOURCE_IMAGE_PREFIX/$service:$version@$digest via $MIRROR_DISPATCH_REPO"
  render_payload "$service" "$version" "$digest" \
    | GH_TOKEN="$MIRROR_DISPATCH_TOKEN" gh api "repos/$MIRROR_DISPATCH_REPO/dispatches" --input - \
    || fail "repository_dispatch to $MIRROR_DISPATCH_REPO failed"
  verify_release "$service" "$version" "$digest"
}

collect_source_natives() {
  local service="$1" version="$2" output="$3"
  local tmp target src
  tmp="$(mktemp "${TMPDIR:-/tmp}/slim-ecr-natives.XXXXXX")"
  for target in "${NATIVE_TARGETS[@]}"; do
    src="$(regctl manifest head "$SOURCE_IMAGE_PREFIX/$service:$version-native-$target" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$src" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      printf '%s\t%s\n' "${version}-native-${target}" "$src" >> "$tmp"
    fi
  done
  python3 - "$tmp" "$output" <<'PY'
import json
import sys

rows = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        tag, digest = line.split("\t", 1)
        rows.append({"tag": tag, "digest": digest})
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(rows, fh)
PY
  rm -f "$tmp"
}

natives_out_of_sync() {
  local service="$1" natives_file="$2"
  local quiet="${3:-}"
  local drift=0 tag digest live
  while IFS=$'\t' read -r tag digest; do
    [[ -n "$tag" ]] || continue
    live="$(destination_digest "$ECR_MIRROR_PREFIX/$service:$tag")"
    if [[ "$live" == "$digest" ]]; then
      [[ -n "$quiet" ]] || log "in sync native: $service $tag ($digest)"
    else
      [[ -n "$quiet" ]] || log "out of sync native: $service $tag (expected $digest, got ${live:-none})"
      drift=1
    fi
  done < <(python3 - "$natives_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    natives = json.load(fh)
for item in natives:
    print(f"{item['tag']}\t{item['digest']}")
PY
)
  return "$drift"
}

# Native copies start after the image tag matches, so they get their own wait.
wait_natives() {
  local service="$1" natives_file="$2"
  local deadline=$((SECONDS + ECR_MIRROR_TIMEOUT))
  while ! natives_out_of_sync "$service" "$natives_file" quiet; do
    if ((SECONDS >= deadline)); then
      natives_out_of_sync "$service" "$natives_file"
      return 1
    fi
    log "waiting for $service natives"
    sleep "$ECR_MIRROR_POLL_INTERVAL"
  done
  natives_out_of_sync "$service" "$natives_file"
}

list_releases() {
  local releases_json="$1"
  gh api --paginate --slurp \
    "repos/${GITHUB_REPOSITORY:-supabase/slim-services}/releases?per_page=100" \
    > "$releases_json"
  python3 - "$CONFIG_FILE" "$releases_json" <<'PY'
import json
import sys

config_path, releases_path = sys.argv[1:]
with open(config_path, encoding="utf-8") as fh:
    services = json.load(fh)["services"]
with open(releases_path, encoding="utf-8") as fh:
    release_pages = json.load(fh)

# Prefix only: tag_pattern is for payload/request/verify, not the audit set.
# Longest prefix wins so a shorter name cannot steal another service's tags.
prefixes = sorted(
    ((f"{name}-", name) for name in services),
    key=lambda item: len(item[0]),
    reverse=True,
)

for page in release_pages:
    for release in page:
        tag = release.get("tag_name", "")
        if release.get("draft") or release.get("prerelease"):
            continue
        for prefix, service in prefixes:
            if tag.startswith(prefix):
                print(f"{service}\t{tag[len(prefix):]}")
                break
PY
}

sync_releases() {
  local request="$1"
  require_cmd gh
  require_cmd regctl
  init_anonymous_configs
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-ecr-sync.XXXXXX")"
  # EXIT runs after this function returns, so the path cannot be a local.
  ECR_MIRROR_SYNC_TEMP="$temp_dir"
  trap 'rm -rf "${ECR_MIRROR_SYNC_TEMP:-}"' EXIT
  list_releases "$temp_dir/releases.json" > "$temp_dir/releases.tsv"
  [[ -s "$temp_dir/releases.tsv" ]] || fail "no published releases found"

  local drift=0 service version source_digest live natives_file native_drift
  while IFS=$'\t' read -r service version; do
    source_digest="$(regctl manifest head "$SOURCE_IMAGE_PREFIX/$service:$version" | tr -d '[:space:]')" \
      || fail "could not resolve source digest for $service $version"
    live="$(destination_digest "$ECR_MIRROR_PREFIX/$service:$version")"
    natives_file="$temp_dir/natives-$service-$version.json"
    collect_source_natives "$service" "$version" "$natives_file"
    native_drift=0
    natives_out_of_sync "$service" "$natives_file" || native_drift=$?
    if [[ "$live" == "$source_digest" && "$native_drift" -eq 0 ]]; then
      log "in sync: $service $version ($source_digest)"
      continue
    fi
    if [[ "$live" != "$source_digest" ]]; then
      log "out of sync: $service $version (expected $source_digest, got ${live:-none})"
    elif [[ "$native_drift" -ne 0 ]]; then
      log "out of sync: $service $version natives"
    fi
    if [[ "$request" == "true" ]]; then
      NATIVE_ARTIFACTS_FILE="$natives_file" request_release "$service" "$version" "$source_digest"
      wait_natives "$service" "$natives_file" || drift=1
    else
      drift=1
    fi
  done < "$temp_dir/releases.tsv"

  ((drift == 0)) || fail "one or more releases are missing from $ECR_MIRROR_PREFIX"
  log "all published releases are mirrored to $ECR_MIRROR_PREFIX"
}

command="$1"
shift
case "$command" in
  payload)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    validate_release "$1" "$2"
    validate_digest "$3"
    render_payload "$1" "$2" "$3"
    ;;
  request)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    require_cmd gh
    require_cmd regctl
    validate_release "$1" "$2"
    validate_digest "$3"
    request_release "$1" "$2" "$3"
    ;;
  verify)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    require_cmd regctl
    validate_release "$1" "$2"
    validate_digest "$3"
    verify_release "$1" "$2" "$3"
    ;;
  sync)
    request=false
    if [[ "${1:-}" == "--request" ]]; then
      request=true
      shift
    fi
    [[ $# -eq 0 ]] || { usage >&2; exit 2; }
    sync_releases "$request"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
