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

Mirror published slim images to AWS ECR Public through the mirror workflow
hosted in the dispatch repository (supabase/cli by default).

Subcommands:
  payload  Print the repository_dispatch request body for one release.
  request  Send the repository_dispatch event, then poll the destination
           until its index digest matches DIGEST. No-op when the
           destination already matches.
  verify   Poll the destination until its index digest matches DIGEST.
  sync     Compare every published release against the destination
           registry and report drift. With --request, also dispatch a
           mirror request for each missing or mismatched tag and verify
           the result. Exits non-zero while any tag is out of sync.

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
    "$ECR_MIRROR_PREFIX/$service:$version" <<'PY'
import json
import sys

event_type, service, version, source, digest, destination = sys.argv[1:]
print(json.dumps({
    "event_type": event_type,
    "client_payload": {
        "service": service,
        "version": version,
        "source": source,
        "digest": digest,
        "destination": destination,
    },
}, indent=2, sort_keys=True))
PY
}

destination_digest() {
  local reference="$1"
  regctl manifest head "$reference" 2>/dev/null | tr -d '[:space:]' || true
}

verify_release() {
  local service="$1" version="$2" digest="$3"
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
  local destination_ref="$ECR_MIRROR_PREFIX/$service:$version"
  local live
  live="$(destination_digest "$destination_ref")"
  if [[ "$live" == "$digest" ]]; then
    log "destination already matches: $destination_ref@$digest"
    return 0
  fi
  [[ -n "${MIRROR_DISPATCH_TOKEN:-}" ]] || fail "MIRROR_DISPATCH_TOKEN is required to send repository_dispatch"
  log "requesting mirror of $SOURCE_IMAGE_PREFIX/$service:$version@$digest via $MIRROR_DISPATCH_REPO"
  render_payload "$service" "$version" "$digest" \
    | GH_TOKEN="$MIRROR_DISPATCH_TOKEN" gh api "repos/$MIRROR_DISPATCH_REPO/dispatches" --input - \
    || fail "repository_dispatch to $MIRROR_DISPATCH_REPO failed"
  verify_release "$service" "$version" "$digest"
}

list_releases() {
  local releases_json="$1"
  gh api --paginate --slurp \
    "repos/${GITHUB_REPOSITORY:-supabase/slim-services}/releases?per_page=100" \
    > "$releases_json"
  python3 - "$CONFIG_FILE" "$releases_json" <<'PY'
import json
import re
import sys

config_path, releases_path = sys.argv[1:]
with open(config_path, encoding="utf-8") as fh:
    services = json.load(fh)["services"]
with open(releases_path, encoding="utf-8") as fh:
    release_pages = json.load(fh)

for page in release_pages:
    for release in page:
        tag = release.get("tag_name", "")
        if release.get("draft") or release.get("prerelease"):
            continue
        for service, config in services.items():
            prefix = f"{service}-"
            if not tag.startswith(prefix):
                continue
            version = tag[len(prefix):]
            if re.fullmatch(config["tag_pattern"], version):
                print(f"{service}\t{version}")
                break
PY
}

sync_releases() {
  local request="$1"
  require_cmd gh
  require_cmd regctl
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-ecr-sync.XXXXXX")"
  trap 'rm -rf "$temp_dir"' EXIT
  list_releases "$temp_dir/releases.json" > "$temp_dir/releases.tsv"
  [[ -s "$temp_dir/releases.tsv" ]] || fail "no published releases found"

  local drift=0 service version source_digest live
  while IFS=$'\t' read -r service version; do
    source_digest="$(regctl manifest head "$SOURCE_IMAGE_PREFIX/$service:$version" | tr -d '[:space:]')" \
      || fail "could not resolve source digest for $service $version"
    live="$(destination_digest "$ECR_MIRROR_PREFIX/$service:$version")"
    if [[ "$live" == "$source_digest" ]]; then
      log "in sync: $service $version ($source_digest)"
      continue
    fi
    log "out of sync: $service $version (expected $source_digest, got ${live:-none})"
    if [[ "$request" == "true" ]]; then
      request_release "$service" "$version" "$source_digest"
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
