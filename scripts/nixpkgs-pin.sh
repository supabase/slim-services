# shellcheck shell=bash
# Shared nixpkgs pin for host-native build/smoke tooling (sourced, not run).
# Keep in sync with the default pin used by services/*/nix/default.nix (those
# stay self-contained by design). BEAM services keep this package set for the
# glibc floor while importing Elixir/OTP definitions from a newer immutable
# pin. Node services select a versioned nodejs_<major> attribute from this set
# after validating the checked-out upstream runtime declarations.
#
# Provides:
#   NIXPKGS_PIN_URL / NIXPKGS_PIN_SHA256
#   nixpkgs_build_attr ATTR  -> prints the store path of ATTR from the pin
#   nixpkgs_build_file FILE  -> prints the store path of the built derivation in FILE

NIXPKGS_PIN_URL="https://github.com/NixOS/nixpkgs/archive/ac62194c3917d5f474c1a844b6fd6da2db95077d.tar.gz"
NIXPKGS_PIN_SHA256="0v6bd1xk8a2aal83karlvc853x44dg1n4nk08jg3dajqyy0s98np"

nixpkgs_build_attr() {
  local attr="$1"
  PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH" \
    nix-build --no-out-link -E "
      with import (fetchTarball {
        url = \"$NIXPKGS_PIN_URL\";
        sha256 = \"$NIXPKGS_PIN_SHA256\";
      }) { }; $attr
    "
}

nixpkgs_build_file() {
  local file="$1"
  PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH" \
    nix-build --no-out-link "$file"
}
