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
- A floor must never sit above a version the CLI catalog pins: doing so would
  let recipes stop building the version the CLI ships, and that version could
  no longer be hotfixed.
- After merging a fix for a defect in already-published artifacts, dispatch
  `hotfix=true` (with a `hotfix_reason`) on `service-release.yml` for each
  affected published upstream version. This publishes a new revision; it
  never rewrites the one that shipped the defect.

## Verify image changes in CI

Do not local-build artifacts or smoke slim images when `service-release`
can run the same path. Push the branch (and `workflow_dispatch`
`service-release.yml` with `validation_only=true` on the PR ref to build
and smoke without publishing), then watch those GitHub Actions runs.
Publishing, including hotfixes, only runs from `main`.
`scripts/test-identity.sh` and other host-only unit scripts may still
run locally. Build or smoke on the laptop only when CI cannot exercise
the change (no workflow, iterating on a script before push).
