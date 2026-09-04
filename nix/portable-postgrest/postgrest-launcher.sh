#!/usr/bin/sh
set -eu

# A generated wrapper lives beside the real PostgREST ELF.  Resolve the
# artifact root from the invocation path so an extracted archive works from
# any directory and never depends on the host's glibc or library search path.
case "$0" in
  */*) PGRST_BIN_DIR="${0%/*}"; [ -n "$PGRST_BIN_DIR" ] || PGRST_BIN_DIR=/ ;;
  *) PGRST_BIN_DIR=. ;;
esac

PGRST_ROOT="$(CDPATH= cd "$PGRST_BIN_DIR/@ROOT_REL@" && pwd -P)"
PGRST_NAME="${0##*/}"
PGRST_PUBLIC="$PGRST_BIN_DIR/$PGRST_NAME"
PGRST_REAL="$PGRST_BIN_DIR/@REAL_NAME@"
PGRST_LIB_DIR="$PGRST_ROOT/lib"
PGRST_LOADER="$PGRST_ROOT/@LOADER_REL@"

[ -x "$PGRST_LOADER" ] || {
  echo "portable-postgrest: bundled loader is missing or not executable: $PGRST_LOADER" >&2
  exit 127
}
[ -x "$PGRST_REAL" ] || {
  echo "portable-postgrest: real PostgREST executable is missing or not executable: $PGRST_REAL" >&2
  exit 127
}

# The explicit loader path is the complete runtime search path.  Include the
# Debian multiarch directories used by the image extractor as well as lib/ so
# this remains relocatable if a future release moves a non-glibc dependency.
PGRST_LIBRARY_PATH="$PGRST_LIB_DIR"
for PGRST_CANDIDATE in \
  "$PGRST_ROOT/lib"/*-linux-gnu \
  "$PGRST_ROOT/usr/lib"/*-linux-gnu \
  "$PGRST_ROOT/usr/lib"
do
  [ -d "$PGRST_CANDIDATE" ] || continue
  PGRST_LIBRARY_PATH="$PGRST_LIBRARY_PATH:$PGRST_CANDIDATE"
done

# Do not let a caller inject another glibc family, audit module, locale, or
# NSS module path.  Re-add only artifact-owned side-data directories.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT GLIBC_TUNABLES \
  GCONV_PATH LOCALE_ARCHIVE LOCPATH NSS_MODULE_PATH
PGRST_GCONV_PATH=
for PGRST_CANDIDATE in \
  "$PGRST_ROOT/lib/gconv" \
  "$PGRST_ROOT/lib"/*-linux-gnu/gconv \
  "$PGRST_ROOT/usr/lib"/*-linux-gnu/gconv
do
  [ -d "$PGRST_CANDIDATE" ] || continue
  if [ -n "$PGRST_GCONV_PATH" ]; then PGRST_GCONV_PATH="$PGRST_GCONV_PATH:$PGRST_CANDIDATE"; else PGRST_GCONV_PATH="$PGRST_CANDIDATE"; fi
done
[ -z "$PGRST_GCONV_PATH" ] || export GCONV_PATH="$PGRST_GCONV_PATH"
PGRST_LOCALE_ARCHIVE=
for PGRST_CANDIDATE in \
  "$PGRST_ROOT/lib/locale/locale-archive" \
  "$PGRST_ROOT/lib"/*-linux-gnu/locale/locale-archive \
  "$PGRST_ROOT/usr/lib"/*-linux-gnu/locale/locale-archive
do
  [ -f "$PGRST_CANDIDATE" ] || continue
  PGRST_LOCALE_ARCHIVE="$PGRST_CANDIDATE"
  break
done
[ -z "$PGRST_LOCALE_ARCHIVE" ] || export LOCALE_ARCHIVE="$PGRST_LOCALE_ARCHIVE"

# glibc 2.35 (the supported host floor) and the newer bundled loaders both
# support --argv0; preserving the public command identity avoids subtle
# behavior changes in diagnostics and process listings.
exec "$PGRST_LOADER" \
  --argv0 "$PGRST_PUBLIC" \
  --library-path "$PGRST_LIBRARY_PATH" \
  "$PGRST_REAL" "$@"
