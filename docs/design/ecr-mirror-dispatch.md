# ECR Public mirroring via supabase/cli dispatch

Slim images are published to `ghcr.io/supabase/cli/<service>:<version>` by
`.github/workflows/service-release.yml`. This document describes how those
images are also mirrored to AWS ECR Public, reusing the mirror machinery and
AWS credentials that already live in `supabase/cli`, so this repository needs
no AWS access of its own.

## Flow

1. The `publish-image` job publishes the multi-platform image to GHCR and
   records its index digest in `published-image.json`.
2. The `mirror-ecr` job sends a `repository_dispatch` event to `supabase/cli`
   (`scripts/ecr-mirror.sh request`), then polls the destination anonymously
   until its index digest equals the GHCR index digest, or fails after a
   timeout (15 minutes by default).
3. The `publish-release` job appends the ECR references to the release notes
   when the mirror was verified.
4. `.github/workflows/ecr-mirror-check.yml` runs daily and fails when any
   published non-draft/non-prerelease tag that maps to a configured service
   (by `<service>-` prefix) is missing from ECR Public or resolves to a
   different digest. The daily audit does not apply `tag_pattern`, so older
   tags that no longer match the current pattern stay in the compare set.
   Run it manually with `request: true` to re-request out-of-sync tags
   (this is also the backfill path for releases that predate mirroring).

Release-time mirroring (`service-release.yml` `mirror-ecr`) is skipped,
with a workflow notice, until the `CLI_MIRROR_DISPATCH_TOKEN` secret
exists. Once the secret is set, a failed or unverified mirror fails the
release: a release is only done when both registries serve the same
digest. The daily audit always runs; it needs only `gh` and `regctl`.
Dispatch (`request: true`) still requires the token.

## Dispatch contract

The event sent to `POST /repos/supabase/cli/dispatches`:

```json
{
  "event_type": "mirror-slim-image",
  "client_payload": {
    "service": "postgrest",
    "version": "v16.2",
    "source": "ghcr.io/supabase/cli/postgrest:v16.2",
    "digest": "sha256:…",
    "destination": "public.ecr.aws/supabase/cli/postgrest:v16.2"
  }
}
```

The handling workflow in `supabase/cli` must:

- Trigger on `repository_dispatch` with `types: [mirror-slim-image]`.
- Copy `source` to `destination` with a digest-preserving tool
  (`regctl image copy`, `crane cp`, or `akhilerm/tag-push-action`).
  `docker buildx imagetools create` may rewrite the index and change its
  digest; verification here would then fail the release.
- Reject a `source` outside `ghcr.io/supabase/cli/` and a `destination`
  outside `public.ecr.aws/supabase/cli/`, and verify that `source` resolves
  to `digest` before copying. The payload arrives with whatever authority
  holds the dispatch token, so the handler validates it independently.
- Create the ECR Public repository when it does not exist, or the
  `cli/<service>` repositories must be created up front. ECR does not create
  repositories on push.

This repository treats the dispatch as fire-and-forget: success is defined
purely by the destination digest matching, which `scripts/ecr-mirror.sh`
verifies with anonymous pulls.

## Setup checklist

1. Land the `mirror-slim-image` handler in `supabase/cli` (see contract
   above).
2. Create the `cli/<service>` ECR Public repositories for the services in
   `.github/service-release-sources.json`, or grant the handler's role
   `ecr-public:CreateRepository`.
3. Create a token that can send `repository_dispatch` to `supabase/cli`
   (fine-grained PAT with contents read/write on `supabase/cli`, or a GitHub
   App installation token) and store it in this repository as the
   `CLI_MIRROR_DISPATCH_TOKEN` actions secret.
4. Backfill existing releases: run the `ECR mirror check` workflow with
   `request: true`.

## Naming

The destination keeps the `cli/` namespace (`public.ecr.aws/supabase/cli/…`)
instead of joining the existing upstream mirrors at
`public.ecr.aws/supabase/<service>` because slim tags reuse upstream version
strings; `supabase/postgrest:v16.2` is already the upstream image. Keeping
the path identical to GHCR also lets consumers switch registries by swapping
only the registry host prefix.
