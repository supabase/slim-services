# Studio Native Artifact and Slim Image

Studio now follows the repository's native-first contract. The target-native
build produces a relocatable artifact containing the application, its
upstream-selected Node runtime, and a `bin/studio` launcher. Linux Docker
images are assembled from that exact artifact on the generic Distroless Debian
13 base.

## Upstream release contract

- Release channel: published `supabase/studio` Docker tags.
- Current source/image: `2026.08.03-sha-022b374`, commit
  `022b374f2dbd7dab46b3fd5aab92d827b7fa4059`.
- The image's SLSA provenance is the authoritative mapping from Docker tag to
  the full `supabase/supabase` source commit.
- Upstream's production Dockerfile selects Node 22. The build derives that
  major and pnpm `11.13.1` from the checked-out source instead of pinning them
  in this repository.
- Upstream currently defaults `STUDIO_FRAMEWORK=next`; TanStack Start is a
  supported explicit build alternative, not yet the published default. The
  native builder follows the upstream Dockerfile default automatically.

## Artifact layout

```text
rootfs/
├── app/                 # selected framework's production runtime tree
├── node/bin/node        # portable upstream-selected Node runtime
├── node/dylib/          # portable non-glibc Node library closure
└── bin/studio           # host launcher
```

`services/studio/build-host.sh` mirrors upstream's Turbo prune, pnpm install,
and framework-specific production assembly on each target host. This is
required because pnpm resolves native packages for the build platform. The
artifact launcher and smoke test deliberately hide host Node so the bundled
runtime is proven on Linux and macOS.

## Docker image

`Dockerfile.slim` copies only `app/` and `node/` from the artifact onto
`gcr.io/distroless/base-debian13:nonroot`. It does not inherit a second Node
runtime. The existing `_FILE` secret handling entrypoint is retained and now
launches through the bundled Node binary.

## Release automation

Studio is included in both the promoted artifact matrix and the automatic
service-release poller. The poller selects the newest date+commit Docker Hub
tag. The release planner verifies the tag, reads its SLSA provenance, validates
the referenced GitHub commit, then runs the standard linux/amd64, linux/arm64,
and darwin/arm64 artifact-and-image matrix.

## Unreleasable Studio versions (sharp in standalone)

Next 15.5.25+ / 16.3.5 traces optional `sharp` into `.next/standalone`. Slim
floor-check `require()` of `sharp-linux-x64-*.node` segfaults on linux/amd64
without matching `sharp-libvips`. This repository does **not** vendor that
native stack.

- Last slim-buildable tag without that trace: `2026.09.14-sha-4dd8a95`.
- `2026.09.21-sha-512201d` and any later Docker Hub tag whose standalone tree
  still contains `@img/sharp-*.node` **cannot be built** here. Do not force
  rebuild them.
- Slim packaging resumes on the first Studio tag whose self-hosted Next config
  keeps sharp out of the standalone output (`images.unoptimized` plus
  `outputFileTracingExcludes` for `sharp` / `@img`, as in
  [supabase/supabase#50658](https://github.com/supabase/supabase/pull/50658)).
  Until then, only keep the latest *buildable* Studio release; do not carry a
  recipe for the broken window.

This is an explicit unreleasable-window decision, not a `release_floor` bump.

Measurements will enter the generated README tables from the first published
native Studio release manifest.

## Local darwin/arm64 validation

The current release was built through the complete native CI driver and
passed the portable Mach-O audit, macOS floor scan, extracted host-process
smoke with host Node hidden, and archive/checksum generation.

| Metric | Value |
|---|---:|
| Artifact rootfs | `453.3 MiB` |
| `tar.zst` archive | `76.1 MiB` |
| macOS floor | `11.3` |
| Idle host-process RSS | `284.8 MiB` |
| Idle CPU | `0.17%` |

## Image HEALTHCHECK (2026-08)

Busybox `sh`/`wget` plus `PATH` including `/node/bin` so the CLI's
CMD-SHELL `node --eval="fetch(.../api/platform/profile)"` runs. The baked
`HEALTHCHECK` is that same command (60s start period). The image smoke
execs it and waits for `docker inspect` to report `healthy`.
