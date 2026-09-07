#!/usr/bin/sh
set -eu

# The launcher is deliberately relative to its extracted artifact.  It keeps
# the public /node/bin/node path stable while invoking the real Node ELF with
# the loader and libraries shipped beside the artifact. Preserve the logical
# invocation path for process.execPath; only the root used for loader paths is
# resolved through symlinks.
PUBLIC_NODE="$0"
case "$PUBLIC_NODE" in
  /*) ;;
  *) PUBLIC_NODE="${PWD:-.}/$PUBLIC_NODE" ;;
esac
case "$0" in
  */*) NODE_BIN_DIR="${0%/*}"; [ -n "$NODE_BIN_DIR" ] || NODE_BIN_DIR=/ ;;
  *) NODE_BIN_DIR=. ;;
esac
NODE_ROOT="$(CDPATH='' cd "$NODE_BIN_DIR/.." && pwd -P)"
ROOT="$(CDPATH='' cd "$NODE_ROOT/.." && pwd -P)"

LOADER_NAME="@LOADER_NAME@"

GLIBC_DIR="$ROOT/lib"
LOADER="$GLIBC_DIR/$LOADER_NAME"
REAL_NODE="$NODE_ROOT/bin/.node-real"
EXEC_PATH_PRELOAD="$NODE_ROOT/bin/.node-execpath.cjs"

if [ ! -x "$LOADER" ]; then
  echo "portable-node: bundled loader is missing or not executable: $LOADER" >&2
  exit 127
fi
if [ ! -x "$REAL_NODE" ]; then
  echo "portable-node: real Node ELF is missing or not executable: $REAL_NODE" >&2
  exit 127
fi
if [ ! -f "$EXEC_PATH_PRELOAD" ]; then
  echo "portable-node: execPath preload is missing: $EXEC_PATH_PRELOAD" >&2
  exit 127
fi

# The explicit loader path is the complete runtime search path.  Do not let a
# host environment inject libraries or side data from a different glibc
# provenance.
# Do not let an inherited loader, audit, tunable, locale, or NSS setting
# inject host state into the bundled runtime. The launcher repopulates only
# the artifact-owned side-data paths below.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT GLIBC_TUNABLES \
  GCONV_PATH LOCALE_ARCHIVE LOCPATH NSS_MODULE_PATH
if [ -d "$GLIBC_DIR/gconv" ]; then
  export GCONV_PATH="$GLIBC_DIR/gconv"
fi
if [ -f "$GLIBC_DIR/locale/locale-archive" ]; then
  export LOCALE_ARCHIVE="$GLIBC_DIR/locale/locale-archive"
fi
export SLIM_NODE_WRAPPER="$PUBLIC_NODE"

exec "$LOADER" \
  --library-path "$GLIBC_DIR:$NODE_ROOT/dylib" \
  "$REAL_NODE" \
  --require "$EXEC_PATH_PRELOAD" \
  "$@"
