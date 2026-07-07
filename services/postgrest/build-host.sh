#!/usr/bin/env bash
set -euo pipefail
# Host build for darwin targets (invoked by scripts/build-artifact-from-source.sh
# with SERVICE/VERSION/TARGET_OS/ARCH/SOURCE_DIR/ROOTFS/ROOT_DIR set).
#
# PostgREST is a Haskell service; a from-source GHC build on darwin without
# upstream's cachix cache takes hours, and the repo's static Nix experiment is
# Linux-only (macOS has no static linking). So the darwin artifact consumes the
# upstream release binary (pinned by sha256) and repairs its one non-portable
# edge: upstream links libpq from a Homebrew path. We bundle a Nix libpq
# closure into lib/ and rewrite install names so the artifact is relocatable
# with no Homebrew dependency. Recorded in services/postgrest/REPORT.md.

# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nixpkgs-pin.sh
source "$ROOT_DIR/scripts/nixpkgs-pin.sh"

PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"
require_cmd curl
require_cmd nix-build
require_cmd otool
require_cmd install_name_tool
require_cmd shasum

case "$TARGET_OS-$ARCH-$VERSION" in
  darwin-arm64-v14.14)
    archive_url="https://github.com/PostgREST/postgrest/releases/download/v14.14/postgrest-v14.14-macos-aarch64.tar.xz"
    archive_sha256="656f5ece84f5cc269f2337ac3fe658349984a5d28e500edb56f150e3cb2cf1fa"
    ;;
  *)
    fail "no pinned upstream postgrest release for $TARGET_OS/$ARCH $VERSION; add the sha256 pin to services/postgrest/build-host.sh"
    ;;
esac

workdir="$(mktemp -d "${TMPDIR:-/tmp}/postgrest-host-build.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

log "fetching upstream release: $archive_url"
curl -fsSL -o "$workdir/postgrest.tar.xz" "$archive_url"
actual_sha256="$(shasum -a 256 "$workdir/postgrest.tar.xz" | awk '{print $1}')"
[[ "$actual_sha256" == "$archive_sha256" ]] || \
  fail "postgrest release sha256 mismatch: expected $archive_sha256, got $actual_sha256"

mkdir -p "$ROOTFS/bin" "$ROOTFS/lib"
tar -C "$workdir" -xJf "$workdir/postgrest.tar.xz"
install -m 0755 "$workdir/postgrest" "$ROOTFS/bin/postgrest"

log "bundling libpq from pinned nixpkgs"
libpq_store="$(nixpkgs_build_attr libpq)"
cp -L "$libpq_store"/lib/libpq.5*.dylib "$ROOTFS/lib/libpq.5.dylib"
chmod u+w "$ROOTFS/lib/libpq.5.dylib"

log "rewriting Homebrew install names to @rpath"
otool -L "$ROOTFS/bin/postgrest" \
  | awk 'NR > 1 && ($1 ~ "^/opt/homebrew/" || $1 ~ "^/usr/local/") { print $1 }' \
  | while IFS= read -r dep; do
      install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$ROOTFS/bin/postgrest"
    done
install_name_tool -add_rpath "@executable_path/../lib" "$ROOTFS/bin/postgrest"

# Complete the Nix closure of the bundled libpq, rewrite its install names,
# strip, ad-hoc sign, and audit (fails on any remaining /nix/store reference).
"$ROOT_DIR/scripts/portable-darwin-fixup.sh" "$ROOTFS"
