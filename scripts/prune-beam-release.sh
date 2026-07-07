#!/bin/sh
# Trim BEAM release tooling that never runs in a final container.
# Usage: prune-beam-release.sh RELEASE_ROOT
# RELEASE_ROOT is the directory containing erts-*/ and lib/ (e.g. /rootfs/app
# or /rootfs/opt/app/rel/logflare). Runs inside artifact build stages (POSIX sh).
set -eu

release_root="$1"
[ -d "$release_root" ] || { echo "release root not found: $release_root" >&2; exit 1; }

for tool in ct_run dialyzer typer erlc escript yielding_c_fun; do
  rm -f "$release_root"/erts-*/bin/"$tool"
done
rm -rf "$release_root"/lib/dialyzer-*
find "$release_root/lib" -maxdepth 2 -type d \( -name src -o -name include -o -name c_src \) -exec rm -rf {} +
rm -rf "$release_root"/erts-*/doc "$release_root"/erts-*/man
