# Public GitHub Actions security

The public repository uses two separate trust zones:

- Pull requests run only the read-only `Public policy` workflow on a standard
  GitHub-hosted runner. It receives no repository secrets and does not build or
  execute service artifacts.
- Release and artifact workflows remain manual, scheduled, or trusted
  `workflow_call` entry points. Linux builds use the organization-managed
  `large-linux-*` runners.

Every external Action reference must use a full 40-character commit SHA. The
human-readable release tag remains in a same-line comment so Dependabot can
keep the pin current. `scripts/check-actions-pinned.sh` enforces this policy.

## Repository settings

Before changing visibility, inspect and then apply the pre-public settings:

```bash
scripts/configure-public-repository.sh \
  --repository supabase/slim-services \
  --phase pre-public

scripts/configure-public-repository.sh \
  --repository supabase/slim-services \
  --phase pre-public \
  --apply
```

This restricts Actions to GitHub-owned Actions plus the explicit Docker and Nix
allowlist, requires full SHA pins, and makes the default workflow token
read-only.

GitHub disables push rulesets during an internal-to-public conversion. Apply
the post-public phase immediately after the visibility change:

```bash
scripts/configure-public-repository.sh \
  --repository supabase/slim-services \
  --phase post-public \
  --apply
```

The resulting ruleset blocks deletion and force-pushes, requires linear squash
merges, one approval, resolved conversations, and the `public policy` status
check. The release-results GitHub App is the only bypass actor so its generated
documentation PR can continue to merge. The same phase enables private
vulnerability reporting for the public repository.

## Organization runner gate

An organization administrator must verify the runner configuration because the
repository token cannot inspect runner groups:

1. `large-linux-arm` and `large-linux-x86` must be GitHub-hosted larger runners
   or an isolated group restricted to this repository.
2. The group must explicitly allow this repository after it becomes public.
3. Fork pull requests must never target those runner labels.
4. Runner images must be ephemeral and start clean for every release job.

Do not add `pull_request_target`. Any future `pull_request` workflow must stay
read-only, secret-free, and on standard GitHub-hosted runners.
