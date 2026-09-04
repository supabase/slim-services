#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: scripts/release-workflow-decision.sh VALIDATION_ONLY FORCE RELEASE_EXISTS\n' >&2
}

[[ $# -eq 3 ]] || { usage; exit 2; }

validation_only="$1"
force="$2"
release_exists="$3"
for value in "$validation_only" "$force" "$release_exists"; do
  case "$value" in
    true|false) ;;
    *) usage; exit 2 ;;
  esac
done

build=false
publish=false
if [[ "$validation_only" == "true" ]]; then
  # Validation runs always build and smoke, but never replace a release or
  # publish an image, regardless of release existence or force.
  build=true
elif [[ "$release_exists" == "false" || "$force" == "true" ]]; then
  build=true
  publish=true
fi

printf '{"build":%s,"publish":%s}\n' "$build" "$publish"
