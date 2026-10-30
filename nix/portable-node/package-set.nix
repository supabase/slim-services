# Package set that builds a Node service and its portable runtime for the
# upstream-selected Node major. The shared build set is preferred so existing
# majors keep their exact derivations; a major it does not define yet comes
# from the pinned runtime set. The whole Node toolchain (npm hooks, native
# addon compiler) comes from one set, and portable-node bundles the glibc
# family, loader, and compiler runtime from that same set, so the floor checks
# prove host compatibility either way.
{
  pkgs,
  runtimePkgs,
  nodeMajor,
}:
let
  nodeAttribute = "nodejs_${toString nodeMajor}";
in
if builtins.hasAttr nodeAttribute pkgs then
  pkgs
else if builtins.hasAttr nodeAttribute runtimePkgs then
  runtimePkgs
else
  throw "neither pinned nixpkgs set provides ${nodeAttribute} required by upstream"
