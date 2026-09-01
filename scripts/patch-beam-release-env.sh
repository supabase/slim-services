#!/bin/sh
# Make a generated BEAM release env.sh honor an explicit distribution mode.
# Usage: patch-beam-release-env.sh ENV_SH
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 ENV_SH" >&2
  exit 2
fi

env_file=$1
[ -f "$env_file" ] || {
  echo "release env file not found: $env_file" >&2
  exit 1
}

if mode=$(stat -c '%a' "$env_file" 2>/dev/null); then
  :
else
  mode=$(stat -f '%Lp' "$env_file")
fi

tmp_file=$(mktemp "${env_file}.tmp.XXXXXX")
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT HUP INT TERM

if ! awk '
  BEGIN { found = 0 }
  /^[[:space:]]*(export[[:space:]]+)?RELEASE_DISTRIBUTION=name[[:space:]]*$/ {
    if ($0 ~ /^[[:space:]]*export[[:space:]]+/) {
      print "export RELEASE_DISTRIBUTION=\"${RELEASE_DISTRIBUTION:-name}\""
    } else {
      print "RELEASE_DISTRIBUTION=\"${RELEASE_DISTRIBUTION:-name}\""
    }
    found++
    next
  }
  { print }
  END {
    if (found != 1) exit 1
  }
' "$env_file" >"$tmp_file"; then
  echo "unable to patch release distribution in: $env_file" >&2
  exit 1
fi

chmod "$mode" "$tmp_file"
mv -f "$tmp_file" "$env_file"
trap - EXIT HUP INT TERM
