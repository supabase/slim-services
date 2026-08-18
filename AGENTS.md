# Repository Instructions

## Release-backlog compatibility

- A polled service's `release_floor` is its compatibility boundary. Service
  recipes, Nix expressions, packaging, audits, and smokes must continue to work
  for every unpublished stable version at or above that floor, not only the
  newest upstream version.
- When adapting a recipe for a newly failing version, preserve the older path.
  Prefer source-tree or dependency feature detection over comparisons against a
  single current version. Keep source refs and derived dependency hashes tied to
  the exact requested version; do not replace them with newest-version pins.
- Before merging a recipe fix, enumerate the service's current unpublished
  backlog and build and smoke every affected backlog version on the current
  platform. Changes to native dependencies, runtime linkage, loaders, or
  platform floors must also run the supported target matrix.
- Do not advance `release_floor`, remove a backlog version, or weaken a smoke to
  hide recipe incompatibility. If an upstream version is genuinely
  unreleasable, record an explicit release-policy decision and a demonstrated
  reason instead of silently skipping it.
