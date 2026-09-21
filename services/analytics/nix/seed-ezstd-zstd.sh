#!/usr/bin/env bash
# mixRelease copies mixFodDeps with cp --no-preserve=mode, so ezstd's compile
# hook loses +x. Restore a seed-checking stub (the upstream script needs
# sysctl/git/cmake) and seed libzstd so the NIF can link.
set -euo pipefail

mix_deps_path="${1:?mix deps path required}"
zstd_lib="${2:?zstd lib prefix required}"
zstd_dev="${3:?zstd include prefix required}"

ezstd="$mix_deps_path/ezstd"
[[ -d "$ezstd" ]] || {
  printf 'ezstd was locked but mix deps copy is missing: %s\n' "$ezstd" >&2
  exit 1
}
[[ -f "$ezstd/build_deps.sh" ]] || {
  printf 'ezstd compile hook missing: %s\n' "$ezstd/build_deps.sh" >&2
  exit 1
}

# ezstd's Makefile treats this path as "already fetched"; keep the upstream
# layout it compiles against (-I/_build/deps/zstd/lib and -lzstd).
dest="$ezstd/_build/deps/zstd/lib"
mkdir -p "$dest"
[[ -f "$zstd_lib/lib/libzstd.a" ]] || {
  printf 'pinned zstd has no static library: %s/lib/libzstd.a\n' "$zstd_lib" >&2
  exit 1
}
cp "$zstd_lib/lib/libzstd.a" "$dest/"

copied_header=0
for header in zstd.h zstd_errors.h zdict.h; do
  if [[ -f "$zstd_dev/include/$header" ]]; then
    cp "$zstd_dev/include/$header" "$dest/"
    copied_header=1
  fi
done
[[ "$copied_header" -eq 1 ]] || {
  printf 'pinned zstd has no headers under %s/include\n' "$zstd_dev" >&2
  exit 1
}

# make runs ./build_deps.sh before compiling the NIF. Replace the upstream
# hook: it probes sysctl/lsb_release even when libzstd.a is already seeded.
cat >"$ezstd/build_deps.sh" <<'EOF'
#!/bin/sh
set -eu
file="_build/deps/zstd/lib/libzstd.a"
if [ ! -f "$file" ]; then
  printf 'ezstd zstd seed missing: %s\n' "$file" >&2
  exit 1
fi
EOF
chmod 0755 "$ezstd/build_deps.sh"
