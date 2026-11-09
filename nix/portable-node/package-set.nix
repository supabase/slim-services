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
  # Lower bound from the upstream package.json engines.node, or null. The
  # shared build set's Node is frozen at the host-compatibility snapshot, so a
  # package manager that enforces engines fails when upstream raises the
  # minimum patch release past it; the newer runtime set serves those sources.
  minNodeVersion ? null,
}:
let
  nodeAttribute = "nodejs_${toString nodeMajor}";
  satisfies =
    set:
    minNodeVersion == null || builtins.compareVersions set.${nodeAttribute}.version minNodeVersion >= 0;
in
if builtins.hasAttr nodeAttribute pkgs && satisfies pkgs then
  pkgs
else if builtins.hasAttr nodeAttribute runtimePkgs && satisfies runtimePkgs then
  runtimePkgs
else
  throw "neither pinned nixpkgs set provides ${nodeAttribute} satisfying upstream (minimum ${toString minNodeVersion})"
