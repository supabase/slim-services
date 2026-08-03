#!/usr/bin/env bash
set -euo pipefail
# Host build for darwin targets (invoked by scripts/build-artifact-from-source.sh
# with SERVICE/VERSION/TARGET_OS/ARCH/SOURCE_DIR/ROOTFS/ROOT_DIR set).
#
# PostgREST is a Haskell service; a from-source GHC build on darwin without
# upstream's cachix cache takes hours, and the repo's static Nix experiment is
# Linux-only (macOS has no static linking). So the darwin artifact consumes the
# upstream release binary and repairs its one non-portable edge: upstream links
# libpq from a Homebrew path. The release planning job supplies the exact asset
# URL and GitHub-computed SHA-256 after validating the stable upstream tag. We
# verify that digest here, bundle a Nix libpq closure into lib/, and rewrite
# install names so the artifact is relocatable with no Homebrew dependency.
# Recorded in services/postgrest/REPORT.md.

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

workdir="$(mktemp -d "${TMPDIR:-/tmp}/postgrest-host-build.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

[[ "$TARGET_OS-$ARCH" == "darwin-arm64" ]] || \
  fail "unsupported PostgREST host target: $TARGET_OS/$ARCH"

# Generic artifact builds do not pass through the release planning job. Keep
# that path automatic too by resolving the same GitHub-computed digest from
# the public release API.
if [[ -z "${UPSTREAM_ASSET_URL:-}" || -z "${UPSTREAM_ASSET_SHA256:-}" ]]; then
  require_cmd python3
  asset_name="postgrest-$VERSION-macos-aarch64.tar.xz"
  release_json="$workdir/release.json"
  curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    -o "$release_json" \
    "https://api.github.com/repos/PostgREST/postgrest/releases/tags/$VERSION"
  asset_metadata="$(python3 - "$release_json" "$asset_name" <<'PY'
import json
import sys

release_path, asset_name = sys.argv[1:]
with open(release_path, encoding="utf-8") as fh:
    release = json.load(fh)

matches = [asset for asset in release.get("assets", []) if asset.get("name") == asset_name]
if len(matches) != 1:
    raise SystemExit(f"expected one upstream asset named {asset_name}, found {len(matches)}")

asset = matches[0]
print(asset.get("browser_download_url", ""), asset.get("digest", ""), sep="\t")
PY
  )"
  IFS=$'\t' read -r UPSTREAM_ASSET_URL upstream_asset_digest <<< "$asset_metadata"
  UPSTREAM_ASSET_SHA256="${upstream_asset_digest#sha256:}"
fi

asset_name="postgrest-$VERSION-macos-aarch64.tar.xz"
expected_asset_url="https://github.com/PostgREST/postgrest/releases/download/$VERSION/$asset_name"
[[ "$UPSTREAM_ASSET_URL" == "$expected_asset_url" ]] || \
  fail "unexpected PostgREST release asset URL: $UPSTREAM_ASSET_URL"
[[ "${UPSTREAM_ASSET_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || \
  fail "UPSTREAM_ASSET_SHA256 is not a valid SHA-256 digest"

archive_url="$UPSTREAM_ASSET_URL"
archive_sha256="$UPSTREAM_ASSET_SHA256"

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
