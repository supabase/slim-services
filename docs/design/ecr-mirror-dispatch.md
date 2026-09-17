# ECR Public mirroring via supabase/cli dispatch

Slim images are published to `ghcr.io/supabase/cli/<service>:<version>` by
`.github/workflows/service-release.yml`. Native archives are published to
GitHub Releases and as OCI artifacts on the same GHCR repository under
`<version>-native-<target>`. This document describes how both are mirrored to
AWS ECR Public, reusing the mirror machinery and AWS credentials in
`supabase/cli`, so this repository needs no AWS access of its own.

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
   and then copies each native tag. Image destination digest must match or
   the sender fails the release (once `CLI_MIRROR_DISPATCH_TOKEN` exists).
   Native copy is best-effort: failure must not fail `publish-release`.
5. Do not skip the dispatch when the image destination already matches;
   natives may have changed. Never prune untagged GHCR or ECR manifests:
   already-shipped CLIs still pin old image digests until a catalog PR ships.
6. `publish-release` `--clobber`s GitHub Release assets on `force=true`.
   GHCR image tags move on push. ECR Public tags are always mutable;
   `aws ecr-public create-repository` accepts no `--image-tag-mutability` flag.
7. Daily `ecr-mirror-check.yml` compares images **and** native tags. Manual
   `request: true` backfills.

Release-time mirroring (`service-release.yml` `mirror-ecr`) is skipped,
with a workflow notice, until the `CLI_MIRROR_DISPATCH_TOKEN` secret
exists. Once the secret is set, a failed or unverified **image** mirror
fails the release. Native ECR copy never gates the GitHub Release.

## Dispatch contract

```json
{
  "event_type": "mirror-slim-image",
  "client_payload": {
    "service": "postgrest",
    "version": "v16.2",
    "source": "ghcr.io/supabase/cli/postgrest:v16.2",
    "digest": "sha256:…",
    "destination": "public.ecr.aws/supabase/cli/postgrest:v16.2",
    "natives": [
      {
        "tag": "v16.2-native-linux-arm64",
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

This repository treats image-mirror success as the destination digest
matching, which `scripts/ecr-mirror.sh` verifies with anonymous pulls.
Native destination drift is reported by the daily audit.

## Follow-up

Agent sandbox default allowlists often permit `public.ecr.aws` and
`ghcr.io` but deny the blob CDNs those registries redirect to
(`*.cloudfront.net`, `pkg-containers.githubusercontent.com`), and they
proxy-scope GitHub release assets to attached repositories
([claude-code#71629](https://github.com/anthropics/claude-code/issues/71629)).
This cut does not add S3 on `*.amazonaws.com` or a second cloud vendor.
Record drift; do not treat a successful GitHub Release as proof every
sandbox can download natives.

## Naming

Keep the `cli/` namespace (`public.ecr.aws/supabase/cli/…`) so slim tags
do not collide with upstream `public.ecr.aws/supabase/<service>`.
