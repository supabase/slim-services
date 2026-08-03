# Publication data cleanup

Changing this repository from internal to public exposes more than the default
branch. GitHub also makes retained Actions history and logs visible. Releases,
pull requests, commit metadata, tags, and every remaining remote branch must be
treated as publication inputs.

## 1. Inventory

Install Gitleaks and run:

```bash
scripts/audit-public-retained-data.sh --repository supabase/slim-services
```

The audit scans every remote branch and tag, not only `main`. The
`.gitleaksignore` file contains exact fingerprints for known smoke-test
fixtures; broad path or rule exclusions are intentionally prohibited.

Review the reported unmerged branches, pull requests, releases, author email
identities, and release-asset volume. Delete remote branches only after their
owner confirms that their contents are either merged or no longer needed.

## 2. Freeze Actions

Temporarily disable the scheduled polling and release-results workflows before
cleanup. Confirm that no release workflow is running. This prevents new runs
from appearing while retained data is being removed.

## 3. Remove retained Actions logs and artifacts

First inspect the exact scope:

```bash
scripts/purge-actions-retained-data.sh \
  --repository supabase/slim-services
```

Deletion is irreversible and therefore requires both execution and exact-name
confirmation:

```bash
scripts/purge-actions-retained-data.sh \
  --repository supabase/slim-services \
  --execute \
  --confirm-delete-all supabase/slim-services
```

Deleting a run removes its logs and associated artifacts. The script then
deletes any remaining standalone artifacts and verifies both counts are zero.
It refuses to operate after the repository is public.

## 4. Re-audit and unfreeze

Run the full inventory again, confirm that workflow runs and artifacts are
zero, and keep scheduled workflows disabled until the public cutover is
complete. Run them once after publication to establish a clean public history.

GitHub documents the visibility consequences, including public Actions logs,
in [Setting repository visibility](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility).
