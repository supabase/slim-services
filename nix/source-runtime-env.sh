# shellcheck shell=sh

# Source the profile next to the current launcher. This file is inserted
# after a launcher shebang by the native runtime derivation.
SLIM_RUNTIME_PROFILE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)/.runtime-env.sh"
if [ -r "$SLIM_RUNTIME_PROFILE" ]; then
  # shellcheck disable=SC1090 # The profile is generated beside each launcher.
  . "$SLIM_RUNTIME_PROFILE"
fi
