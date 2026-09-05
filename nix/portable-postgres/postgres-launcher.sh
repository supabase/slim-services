#!/usr/bin/sh
set -eu

# A generated wrapper lives beside one real PostgreSQL executable. Keep the
# public path stable while invoking the matching loader and libraries bundled
# at the extracted artifact root.
case "$0" in
  */*) PG_BIN_DIR="${0%/*}"; [ -n "$PG_BIN_DIR" ] || PG_BIN_DIR=/ ;;
  *) PG_BIN_DIR=. ;;
esac
# PostgreSQL derives its share/config paths from argv[0].  Resolve the
# wrapper directory before constructing argv0 and the real executable path so
# a launcher invoked as `./artifacts/.../bin/postgres` remains valid after the
# server changes directory during startup.
PG_BIN_DIR="$(CDPATH= cd "$PG_BIN_DIR" && pwd -P)"

PG_ROOT="$(CDPATH= cd "$PG_BIN_DIR/@ROOT_REL@" && pwd -P)"
PG_NAME="${0##*/}"
PUBLIC_PATH="$PG_BIN_DIR/$PG_NAME"
REAL_POSTGRES="$PG_BIN_DIR/@REAL_NAME@"
LIB_DIR="$PG_ROOT/lib"
LOADER="$LIB_DIR/@LOADER_NAME@"

# PostgreSQL's Nix wrapper uses this directory for extension modules and
# libpq-adjacent support files. Keep the same contract after relocation.
export NIX_PGLIBDIR="$LIB_DIR"

if [ ! -x "$LOADER" ]; then
  echo "portable-postgres: bundled loader is missing or not executable: $LOADER" >&2
  exit 127
fi
if [ ! -x "$REAL_POSTGRES" ]; then
  echo "portable-postgres: real PostgreSQL executable is missing or not executable: $REAL_POSTGRES" >&2
  exit 127
fi
if [ ! -f "$LIB_DIR/locale/locale-archive" ]; then
  echo "portable-postgres: bundled locale archive is missing: $LIB_DIR/locale/locale-archive" >&2
  exit 127
fi

# The explicit loader path is the complete runtime search path. Do not allow a
# host environment to inject a different glibc family or its side data.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT GLIBC_TUNABLES \
  GCONV_PATH LOCALE_ARCHIVE LOCPATH NSS_MODULE_PATH
# Keep PostgreSQL's process locale independent of the invoking host. The
# portable binary uses the bundled en_US.UTF-8 archive below; image tooling
# (BusyBox/Bash in the image) uses the separate system archive generated
# by the image's tools stage.
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8
if [ -d "$LIB_DIR/gconv" ]; then
  export GCONV_PATH="$LIB_DIR/gconv"
fi
export LOCALE_ARCHIVE="$LIB_DIR/locale/locale-archive"

if [ "@ARGV0_SUPPORTED@" = 1 ]; then
  exec "$LOADER" \
    --argv0 "$PUBLIC_PATH" \
    --library-path "$LIB_DIR" \
    "$REAL_POSTGRES" "$@"
fi

exec "$LOADER" \
  --library-path "$LIB_DIR" \
  "$REAL_POSTGRES" "$@"
