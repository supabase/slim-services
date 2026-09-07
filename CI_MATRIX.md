# CI Matrix Contract

The repository publishes a portable archive for each supported service, target
OS, and CPU architecture. Linux Docker images for derived-image services are
assembled from the same artifact rootfs. Mailpit, Vector, and Imgproxy retain
their external archive/source and exact-image mirror paths.

## Matrix

Use explicit target variables rather than inferring from runner labels:

```text
TARGET_OS=linux|darwin
ARCH=arm64|amd64
```

Supported archive outputs are:

```text
artifacts/<service>/<version>/linux-arm64/<service>-<version>-linux-arm64.tar.zst
artifacts/<service>/<version>/linux-amd64/<service>-<version>-linux-amd64.tar.zst
artifacts/<service>/<version>/darwin-arm64/<service>-<version>-darwin-arm64.tar.zst
```

`darwin-amd64` has no supported build or smoke target. Linux target names are
platform names; whether an artifact uses host glibc, static libc, or bundled
libc is recorded by `portable`, `assumed_host_libs`, and `os_floor` in its
manifest. `TARGET_LIBC=musl` is reserved for a future explicit musl target.

## Host floors

Portable linux archives that consume host glibc may require at most **glibc
2.35** from the host (`GLIBC_2.x` Verneed max across all shipped consumer
ELFs; measured and gated by `scripts/audit-portable-artifact.sh`, recorded as
`os_floor` in the manifest). Artifacts with a valid bundled loader+libc pair
report `os_floor.floor: null` because their own glibc defines the runtime floor;
their compatibility is proven by the execution check instead. Supported
host-glibc consumers must provide glibc >= 2.35 (including Ubuntu 22.04+,
Debian 13+, and Fedora 40+). Every linux artifact is additionally executed
inside `ubuntu:22.04` (glibc 2.35 exactly) by
`scripts/floor-check-linux.sh`.
Darwin archives may require at most **macOS 14.0** (Mach-O minos, same
audit). Per-service overrides: `GLIBC_FLOOR_MAX` / `MACOS_FLOOR_MAX` in
`recipe.env`; global: `SLIM_GLIBC_FLOOR_MAX` / `SLIM_MACOS_FLOOR_MAX`.

The current service profiles are: edge-runtime and Mailpit consume host glibc;
Postgres, dynamic Linux PostgREST, imgproxy, the BEAM services, and the Node
services bundle matched loader+glibc runtimes and report a null host floor;
Auth is static and Vector uses musl. Bundled runtimes carry the NSS, gconv,
and locale data required by their own libc.

## Workflows

`.github/workflows/service-release.yml` is the primary publication workflow.
It accepts one service and version, expands the three supported target cells,
and stages each archive with its manifest, SPDX SBOM, and `SHA256SUMS`.
Derived-image services also build and smoke Linux images from the artifact
rootfs; external mirror services verify the selected upstream snapshot and
preserve the image's digest and referrer evidence. The workflow publishes
release assets and, for derived Linux images, the versioned GHCR image after
the checks in the workflow pass.
Pass `validation_only=true` to build, smoke, and upload CI artifacts without
publishing a release or image.

Use the repository's release policy and workflow as the source of truth for
which service versions are eligible. This document does not assert that the
latest upstream version has been built or released.

`.github/workflows/service-artifacts.yml` is the manual diagnostic workflow.
Its `workflow_dispatch` inputs select services, targets, explicitly selected
external versions, and whether to rebuild cached artifacts. It runs the
selected matrix, uploads archives/manifests/SBOMs/checksums for inspection,
and can refresh result tables from the manifests. It is useful for exercising
individual cells and diagnosing a release; it is not the service-release
publication path.

## One-service command

For a single matrix cell:

```bash
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh edge-runtime v1.73.15
TARGET_OS=linux ARCH=amd64 scripts/ci-build-service.sh edge-runtime v1.73.15
TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh edge-runtime v1.73.15
```

The command builds the artifact rootfs, runs the applicable portability audit
and floor check, creates the distribution archive and checksum, and performs
the target's service smoke. On Linux derived-image services it then builds and
smokes the Docker image from that rootfs and records its compressed image size.
For mirror services it skips artifact-derived image construction.

The workflows separately smoke the Linux rootfs as a host process to exercise
the native CLI path. That step runs against the checked-out rootfs; it does
not extract and re-smoke the distribution archive. Darwin smokes run the
matching rootfs directly on the macOS runner. Host-process measurements and
Docker measurements use different samplers and are not interchangeable.

## Runner requirements

Linux runners need Docker for image smokes and upstream image inspection,
Nix with flakes enabled for native builds and archive/image assembly, and a runner architecture that
matches `ARCH` for native artifact execution. macOS runners need Nix with
flakes enabled, matching architecture for direct smoke, and Xcode command-line
tools when a package requires Mach-O inspection or signing. macOS CI uses the
Docker-free harness Postgres path (`SLIM_SMOKE_HOST_POSTGRES=1`).

## Smoke entry points

All service smokes are invoked through:

```bash
scripts/smoke.sh <service> --artifact <rootfs>
scripts/smoke.sh <service> --image <image>
```

Artifact smokes receive `ARTIFACT_ROOTFS` when they run directly. Direct host
execution requires a matching artifact target and a service recipe with
`SUPPORTS_DIRECT_ARTIFACT_SMOKE="true"`. Without the explicit Linux direct
smoke flag, `scripts/smoke.sh --artifact` builds a temporary image from a Linux
rootfs. The host-process branch applies a service's `runtime.env` only when
that file exists.

## Submodules

CI initializes source submodules and requires them to remain clean and pinned:

```bash
git submodule update --init --recursive
git submodule status --recursive
```

Artifact builders fail if a source submodule is dirty or does not resolve to
the recipe's requested ref.
