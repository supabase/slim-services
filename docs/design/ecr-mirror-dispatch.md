# ECR Public mirroring via supabase/cli dispatch

Every release is published under an immutable revision `<U>-r<N>`: `U` is the
upstream version and `N` is a packaging revision, allocated from the full
paginated GitHub release list before any push. The GitHub release
`<service>-<U>-r<N>` is the commit point — `gh release create` is create-only,
so once that release exists, nothing ever republishes bytes under that name
again. A hotfix publishes a new, higher `N`; it never touches a previously
published revision.

Slim images are published to `ghcr.io/supabase/cli/<service>:<U>-r<N>` by
`.github/workflows/service-release.yml`. Native archives are published to
GitHub Releases and as OCI artifacts on the same GHCR repository under
`<U>-r<N>-native-<target>`. This document describes how both are mirrored to
AWS ECR Public and to S3, reusing the mirror machinery and AWS credentials in
`supabase/cli`, so this repository needs no AWS access of its own. ECR Public
and S3 are copies, not sources of truth: they are reconciled against the
committed GHCR digests, and a mismatch is repaired by backfilling, never by
republishing the release.

CLI consumption, env-hint candidate order, and shipped digest-pin lag are
recorded in supabase/cli
[ADR 0026](https://github.com/supabase/cli/blob/develop/docs/adr/0026-slim-artifact-mirrors.md).

## Flow

1. `publish-image` publishes the multi-platform image to GHCR.
2. `publish-natives` (after `build`) pushes the native triplet
   (`tar.zst`, `manifest.json`, checksum) to
   `ghcr.io/supabase/cli/<service>:<version>-native-<target>` for
   `linux-arm64`, `linux-amd64`, and `darwin-arm64`. Do not use
   `<version>-linux-*`; those tags are image platform manifests.
   This job is best-effort (`continue-on-error`) and must not fail
   `publish-release`.
3. `mirror-ecr` needs both publish jobs. It dispatches `mirror-slim-image`
   with the **image** `service` / `version` / `digest` plus
   `natives: [{tag, digest}, ...]`. Catalog sync reads only the image fields.
4. The cli handler copies the image (digest-preserving `regctl image copy`)
   and then copies each native tag. `mirror-ecr` waits, within one shared
   timeout, for the image digest on ECR Public and each native `SHA256SUMS`
   on S3, and reports each destination separately. Either one missing fails
   `mirror-ecr` (once `CLI_MIRROR_DISPATCH_TOKEN` exists), which marks the
   run red but does not stop `publish-release`; the ECR lines in the release
   notes only depend on the image check. Native ECR copy is best-effort and
   only enforced under `ECR_MIRROR_REQUIRE_NATIVES=1`.
5. A second cli job, independent of the ECR job, copies the same native
   triplets to a public-read S3 bucket in a dedicated AWS account, for
   sandboxes that allow `*.amazonaws.com` but block registry blob CDNs and
   unattached GitHub release assets. An ECR Public outage or permission gap
   never holds it back. It verifies the source image digest, re-fetches each
   native from GHCR by digest, checks the archive against its `SHA256SUMS`
   and the manifest against the dispatch fields, then uploads under the
   release asset names to
   `https://supabase-cli-artifacts.s3.us-east-1.amazonaws.com/<service>/<version>/<service>-<version>-<target>.{tar.zst,manifest.json,SHA256SUMS}`.
   This repository verifies an S3 copy by hashing the anonymous
   `SHA256SUMS` object against the checksum layer digest of the GHCR native.
6. Do not skip the dispatch when the image destination already matches;
   natives may have changed. Never prune untagged GHCR or ECR manifests:
   already-shipped CLIs still pin old image digests until a catalog PR ships.
7. `publish-release` creates the GitHub release once and only once for a
   given `<service>-<U>-r<N>`; there is no clobber path. Before that
   commit point, GHCR writes to the not-yet-committed `-rN` tag may
   overwrite leftovers from a failed attempt at the same `N`; ECR Public
   tags are always mutable (`aws ecr-public create-repository` accepts no
   `--image-tag-mutability` flag) and S3 objects are overwritten in place
   (versioned, so a bad overwrite can be recovered on the cli side), so
   both can briefly hold bytes from an earlier failed attempt until the
   release commits.
8. Daily `ecr-mirror-check.yml` compares images on ECR Public, native tags
   on ECR Public, and native triplets on S3, each independently, for the
   latest release of each service release line (every release with
   `all_releases: true`, or exact `SERVICE:VERSION` selections). A
   published release with no GHCR image (older postgres releases predate
   image publication) is skipped and counted, never fatal. ECR image drift
   and S3 native drift fail the audit; ECR native drift is reported and
   only fails it when `ECR_MIRROR_REQUIRE_NATIVES=1`. Manual
   `request: true` backfills: it dispatches every out-of-sync release first
   and then waits for all of them within one shared timeout, so an
   unreachable destination (for example ECR Public before its repositories
   and permissions exist) costs one timeout and still lets the S3 copy of
   every release land. Use the `services` input (`postgrest` or
   `postgrest:v16.2-r0`, space-separated) to backfill in slices so one run
   does not flood the cli runners. Legacy releases without `-rN` are frozen
   and excluded from both the audit and the backfill. A release published
   before native OCI tags existed has no natives to mirror; since revisions
   are immutable, publish a hotfix (`hotfix=true` on `service-release.yml`)
   to get a new revision with natives, rather than rebuilding the old one.

Release-time mirroring (`service-release.yml` `mirror-ecr`) is skipped,
with a workflow notice, until the `CLI_MIRROR_DISPATCH_TOKEN` secret
exists. Once the secret is set, a failed or unverified image mirror or S3
native copy fails the `mirror-ecr` job and the run, but the GitHub Release
is still published (with a warning, and without the ECR lines in its notes
when the image did not verify). Mirroring never gates the GitHub Release:
mirror-side problems are repaired by backfilling with
`ecr-mirror-check.yml` (`request: true`), not by rebuilding the release.

## Dispatch contract

```json
{
  "event_type": "mirror-slim-image",
  "client_payload": {
    "service": "postgrest",
    "version": "v16.2-r0",
    "source": "ghcr.io/supabase/cli/postgrest:v16.2-r0",
    "digest": "sha256:…",
    "destination": "public.ecr.aws/supabase/cli/postgrest:v16.2-r0",
    "natives": [
      {
        "tag": "v16.2-r0-native-linux-arm64",
        "digest": "sha256:…"
      }
    ]
  }
}
```

The handler in `supabase/cli` must:

- Trigger on `repository_dispatch` with `types: [mirror-slim-image]`.
- Derive source and destination from `service` + `version`; do not trust
  payload URL strings except to require they match the derived values.
- Copy image by digest with `regctl image copy` (not `docker buildx
  imagetools create`).
- Copy each native tag the same way, without `--referrers`. Raise the job
  timeout still under the sender’s poll window.
- Create `cli/<service>` if missing. Do not pass a mutability flag.
- Treat `natives[]` as optional extra data. Catalog sync consumes only
  image `service` / `version` / `digest`.
- For the S3 copy, source each native from GHCR by the `natives[]` digest
  (the GitHub Release does not exist yet when the dispatch fires), keep the
  release asset names as object keys, and upload the `SHA256SUMS` last.
  Use a credential that can only `PutObject` on that bucket.

This repository treats image-mirror success as the destination digest
matching, which `bun scripts/ecr-mirror.ts` verifies with anonymous pulls,
and S3 success as the anonymous `SHA256SUMS` object matching the GHCR
checksum layer. ECR native drift is reported by the daily audit and becomes
a failure only once `ECR_MIRROR_REQUIRE_NATIVES=1` is set.

## `slim-release-published` dispatch

`mirror-ecr` runs before `publish-release`, so its `mirror-slim-image`
dispatch above fires before the revision is committed and cannot be used to
tell the CLI a release exists. Instead, the last step of `publish-release`
sends a second, independent `repository_dispatch` to the same CLI repository
(reusing `MIRROR_DISPATCH_REPO` and `CLI_MIRROR_DISPATCH_TOKEN`) once the
GitHub release has been created:

```json
{
  "event_type": "slim-release-published",
  "client_payload": {
    "service": "postgrest",
    "upstream_version": "v16.2",
    "revision": 0,
    "release_version": "v16.2-r0"
  }
}
```

Unlike the mirror dispatch, a missing token or a failed dispatch fails the
run: the release already exists by this point, so a failure means the CLI
must be told by hand, not that anything needs to be republished. A CLI
workflow consumes this to sync its artifact catalog to the new revision.

## Follow-up

Agent sandbox default allowlists often permit `public.ecr.aws` and
`ghcr.io` but deny the blob CDNs those registries redirect to
(`*.cloudfront.net`, `pkg-containers.githubusercontent.com`), and they
proxy-scope GitHub release assets to attached repositories
([claude-code#71629](https://github.com/anthropics/claude-code/issues/71629)).
The S3 copy on `*.amazonaws.com` (step 5 above) is the answer for those
sandboxes; no second cloud vendor is added. Record drift; do not treat a
successful GitHub Release as proof every sandbox can download natives.

## Naming

Keep the `cli/` namespace (`public.ecr.aws/supabase/cli/…`) so slim tags
do not collide with upstream `public.ecr.aws/supabase/<service>`.
