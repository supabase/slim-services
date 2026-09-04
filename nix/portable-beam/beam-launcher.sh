#!/usr/bin/sh
set -eu

# A generated wrapper lives beside one real ERTS executable.  Keep the public
# path stable while invoking the matching loader and libraries bundled at the
# extracted artifact root.
case "$0" in
  */*) BEAM_BIN_DIR="${0%/*}"; [ -n "$BEAM_BIN_DIR" ] || BEAM_BIN_DIR=/ ;;
  *) BEAM_BIN_DIR=. ;;
esac

CDPATH=
BEAM_ROOT="$(cd "$BEAM_BIN_DIR/@ROOT_REL@" && pwd -P)"
BEAM_NAME="${0##*/}"
PUBLIC_PATH="$BEAM_BIN_DIR/$BEAM_NAME"
REAL_BEAM="$BEAM_BIN_DIR/@REAL_NAME@"
GLIBC_DIR="$BEAM_ROOT/lib"
DYLIB_DIR="$BEAM_ROOT/dylib"
LOADER="$GLIBC_DIR/@LOADER_NAME@"

if [ ! -x "$LOADER" ]; then
  echo "portable-beam: bundled loader is missing or not executable: $LOADER" >&2
  exit 127
fi
if [ ! -x "$REAL_BEAM" ]; then
  echo "portable-beam: real BEAM executable is missing or not executable: $REAL_BEAM" >&2
  exit 127
fi

# The explicit loader path is the complete runtime search path.  Do not allow
# a host environment to inject a different glibc family or its side data.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT GLIBC_TUNABLES \
  GCONV_PATH LOCALE_ARCHIVE LOCPATH NSS_MODULE_PATH
if [ -d "$GLIBC_DIR/gconv" ]; then
  export GCONV_PATH="$GLIBC_DIR/gconv"
fi
if [ -f "$GLIBC_DIR/locale/locale-archive" ]; then
  export LOCALE_ARCHIVE="$GLIBC_DIR/locale/locale-archive"
fi

ARGV0_SUPPORTED="@ARGV0_SUPPORTED@"
case "$ARGV0_SUPPORTED" in
  1)
    exec "$LOADER" \
      --argv0 "$PUBLIC_PATH" \
      --library-path "$GLIBC_DIR:$DYLIB_DIR" \
      "$REAL_BEAM" "$@"
    ;;
esac

exec "$LOADER" \
  --library-path "$GLIBC_DIR:$DYLIB_DIR" \
  "$REAL_BEAM" "$@"
