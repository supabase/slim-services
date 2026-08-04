# Public repository cutover

The public cutover is intentionally split across four reviewable changes:

1. Artifact licensing, notices, and SPDX SBOMs.
2. Published-history inventory and retained Actions data cleanup.
3. Immutable Actions, least-privilege settings, and public branch policy.
4. This final verification and cutover orchestrator.

Merge the changes in that order. Do not run the cutover from an unreviewed
branch.

## Prepare

1. Obtain legal approval for the Apache-2.0 repository license and all
   third-party redistribution obligations.
2. Rebuild every release with three SPDX SBOM assets and embedded
   `share/licenses/` material, or delete releases that will not be republished.
3. Run `scripts/audit-public-retained-data.sh`, review every unmerged branch,
   PR, commit identity, and release, then remove stale branches.
4. Freeze scheduled workflows and run the confirmed
   `scripts/purge-actions-retained-data.sh` cleanup.
5. Have an organization administrator attest that the `large-linux-*` runner
   policy satisfies `docs/PUBLIC_ACTIONS_SECURITY.md`.
6. Merge all four public-gate PRs and run the `Public readiness` workflow from
   `main`.

## Preview the cutover

```bash
scripts/publish-repository.sh --repository supabase/slim-services
```

The preview does not change settings or visibility.

## Execute

The operator must record all four human approvals in the environment and repeat
the exact repository name:

```bash
LEGAL_REVIEW_APPROVED=1 \
RELEASE_ASSETS_APPROVED=1 \
PUBLICATION_CONTENT_REVIEW_APPROVED=1 \
RUNNER_POLICY_APPROVED=1 \
scripts/publish-repository.sh \
  --repository supabase/slim-services \
  --execute \
  --confirm-public supabase/slim-services
```

The command applies least-privilege Actions settings, verifies all pre-public
conditions, accepts GitHub's visibility-change consequences, recreates the
strong branch ruleset, enables private vulnerability reporting, and repeats
the complete verification against the public repository. It stops immediately
on any failed gate.

## Recovery

If the visibility change succeeds but a post-public check fails, do not switch
back automatically. Run the post-public settings phase again, inspect the
failed check, and keep releases and scheduled workflows frozen until
`scripts/verify-public-readiness.sh --phase post-public` passes. Changing
visibility again has additional fork and ruleset consequences.
