# shellcheck shell=sh

# Source the profile next to the current launcher. This file is inserted
# after a launcher shebang by the native runtime derivation. Keep the
# directory lookup to POSIX shell builtins: minimal service images do not
# necessarily contain coreutils such as dirname.
case "$0" in
  */*) SLIM_RUNTIME_DIR=${0%/*} ;;
  *) SLIM_RUNTIME_DIR=. ;;
esac
SLIM_RUNTIME_DIR="$(CDPATH='' cd -- "$SLIM_RUNTIME_DIR" && pwd -P)"
SLIM_RUNTIME_PROFILE="$SLIM_RUNTIME_DIR/.runtime-env.sh"
if [ -r "$SLIM_RUNTIME_PROFILE" ]; then
  # shellcheck disable=SC1090 # The profile is generated beside each launcher.
  . "$SLIM_RUNTIME_PROFILE"
fi
