#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 3 ]] || {
  echo "usage: copy-source-notice.sh SOURCE_ARCHIVE NOTICE_NAME DESTINATION" >&2
  exit 2
}

source_archive="$1"
notice_name="$2"
destination="$3"
notice_member="$(
  tar -tf "$source_archive" |
    awk -v suffix="/$notice_name" '
      length($0) >= length(suffix) &&
      substr($0, length($0) - length(suffix) + 1) == suffix {
        if (first == "") first = $0
      }
      END { if (first != "") print first }
    '
)"
[ -n "$notice_member" ] || {
  echo "missing $notice_name in pinned source archive $source_archive" >&2
  exit 1
}

tar -xOf "$source_archive" "$notice_member" > "$destination"
