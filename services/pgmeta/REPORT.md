# PgMeta Native Artifact and Slim Image

PgMeta follows the native-first Node service contract. Its target-native build
runs the upstream TypeScript build, prunes to production dependencies, bundles
the upstream-selected Node runtime, and emits a relocatable launcher.

## Build and runtime contract

- Source: the exact stable `supabase/postgres-meta` release selected by the
  release workflow.
- Node major: derived from the checked-out upstream Dockerfile and checked
  against `.nvmrc`; the same major builds native addons and is bundled into the
  artifact.
- Artifact layout: `app/`, `node/`, and `bin/pgmeta`.
- External runtime requirement: none (`runtime_requires` is null).
- Linux host contract: host glibc only; Node's non-glibc library closure is
  carried under `node/dylib/`.
- Smoke: `/health` returns 200 with host Node hidden, both as an extracted host
  process and through the derived Linux image.

The final image uses `gcr.io/distroless/base-debian13:nonroot`, copies the
artifact's `app/` and `node/` trees, and starts `/node/bin/node` directly.
There is no second Node runtime inherited from the base image.

Historical Rolldown and Sentryless variants were not adopted and their
Dockerfile/overlay implementation has been removed. PgMeta intentionally keeps
the upstream TypeScript output because those experiments saved too little to
justify a permanent alternate packaging path.

Current published measurements are generated from release manifests in the
README results tables.
