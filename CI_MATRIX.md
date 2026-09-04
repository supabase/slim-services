# CI Matrix Contract

This repo is designed around portable archives per supported service, OS, and
CPU architecture, plus Docker images for Linux targets.

## Matrix

Use explicit target variables instead of inferring from runner labels:

```text
TARGET_OS=linux|darwin
ARCH=arm64|amd64
```

The current intended archive outputs are:

```text
artifacts/<service>/<version>/linux-arm64/<service>.tar.zst
artifacts/<service>/<version>/linux-amd64/<service>.tar.zst
artifacts/<service>/<version>/darwin-arm64/<service>.tar.zst
```

`linux-<arch>` archives are glibc artifacts. The libc flavor is part of the
target name only when it is not glibc: future Alpine targets will publish
`linux-<arch>-musl` archives (`TARGET_LIBC=musl`, reserved — no musl builds
exist yet). There is deliberately no `-gnu` suffix.

## Host Floor Policy

Portable linux archives may require at most **glibc 2.35** from the host
(`GLIBC_2.x` Verneed max across all shipped ELFs; measured and gated by
`scripts/audit-portable-artifact.sh`, recorded as `os_floor` in the
manifest). Supported hosts must provide glibc >= 2.35 (including Ubuntu
22.04+, Debian 13+, and Fedora 40+). Every linux artifact is additionally
executed inside `ubuntu:22.04` (glibc 2.35 exactly) by
`scripts/floor-check-linux.sh`.
Darwin archives may require at most **macOS 14.0** (Mach-O minos, same
audit). Per-service overrides: `GLIBC_FLOOR_MAX` / `MACOS_FLOOR_MAX` in
`recipe.env`; global: `SLIM_GLIBC_FLOOR_MAX` / `SLIM_MACOS_FLOOR_MAX`.

`darwin/amd64` is intentionally out of scope for now: GitHub-hosted Intel
macOS runners are gone from the free tier (`macos-14`+ are arm64-only; Intel
survives only as paid `-large` runners), so there is no runner to build or —
more importantly — validate Intel artifacts on. Revisit only if Intel-Mac
demand shows up, with paid large runners or self-hosted Intel hardware.

Docker images are produced only for Linux targets. The GitHub Actions workflow
publishes a multi-platform GHCR manifest under the version tag:

```text
ghcr.io/supabase/slim-services/edge-runtime:<version>
```

## One-Service CI Command

For a single matrix cell:

```bash
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh edge-runtime v1.73.15
TARGET_OS=linux ARCH=amd64 scripts/ci-build-service.sh edge-runtime v1.73.15
TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh edge-runtime v1.73.15
```

The manual GitHub Actions entrypoint for the current Edge Runtime matrix is
`.github/workflows/edge-runtime-artifacts.yml`. It builds the three supported
archives, builds and smokes Linux Docker images, uploads only the `.tar.zst`
portable archive for each target, pushes the Linux platform images by digest,
and publishes a multi-platform version tag:
`ghcr.io/supabase/slim-services/edge-runtime:<version>`.
Archive filenames include service, version, and platform, for example:
`edge-runtime-v1.73.15-linux-arm64.tar.zst`.

Every other promoted service builds through
`.github/workflows/service-artifacts.yml`: a `workflow_dispatch` matrix of
services (auth, postgrest, realtime, pooler, analytics, storage, edge-runtime,
studio, pgmeta, postgres)
times targets (`linux-arm64` on `ubuntu-24.04-arm`, `linux-amd64` on
`ubuntu-24.04`, `darwin-arm64` on `macos-14`), each running
`scripts/ci-build-service.sh` and uploading the archive, `SHA256SUMS`, and
`manifest.json`. macOS runners have no Docker, so darwin smokes run with
`SLIM_SMOKE_HOST_POSTGRES=1` (harness postgres as a host process from the
shared nixpkgs pin). Linux jobs additionally smoke the artifact as a real
host process (`SLIM_DIRECT_LINUX_ARTIFACT_SMOKE=1`) — the CLI's no-Docker
mode — on top of the derived-image smoke.

Mailpit and Vector are upstream-archive/mirror entries selected explicitly for
artifact runs through the `external_versions` JSON input. Imgproxy is a
source-built Nix/external-source mirror entry selected the same way, with its
explicit `vMAJOR.MINOR.PATCH` version. Mailpit and Vector's three native
archives use the same target matrix and direct artifact smoke; imgproxy uses
its pinned Nix source snapshot. The Linux release path skips derived-image
construction and mirrors the exact OCI index resolved at plan time. The
release workflow freezes one descriptor-derived snapshot (including archive,
source, and platform digests) and every consumer verifies that same run-scoped
artifact before loading a recipe. Historical release facts remain in the
service reports; no current version is required in the checkout.

Native-first (HOST_NATIVE_PLAN.md): the archive on every target is the
host-native artifact — relocatable, audit-clean, runnable straight from the
extracted archive (only the glibc family assumed on Linux, libSystem on
macOS; each Node service bundles its upstream-selected Node runtime inside the archive — the
wrapper prefers `node/bin/node`, no external runtime, `runtime_requires` is
null). The Docker image for Linux targets is derived from that same rootfs
by `Dockerfile.slim` (base + artifact + entry wiring). `darwin-amd64` is not
built — see below.

The workflow installs Nix with `nixbuild/nix-quick-install-action` and caches
the Nix store with `nix-community/cache-nix-action`:

- `nixbuild/nix-quick-install-action` installs single-user Nix on the runner.
- `nix-community/cache-nix-action` restores and saves `/nix` using a cache key
  scoped to the runner OS, target OS, target architecture, Edge Runtime
  `flake.lock`, and our repo-owned Edge Runtime Nix overlay/recipe files.
- `DeterminateSystems/flake-checker-action` checks
  `sources/edge-runtime/flake.lock` so we get early visibility into stale or
  unhealthy flake inputs.

With this setup, CI uses Nix's default public binary cache plus the GitHub
Actions cache. Store paths missing from those caches are built locally by the
runner and retained by the GitHub Actions cache for later runs. The workflow
intentionally uses the backend's plain `nix build` path for now so cache
behavior is easier to inspect.

GitHub Actions cache requires the repository to have a default branch. If
`cache-nix-action` logs `Default branch not found for repository`, cache restore
and save will not work even for a cache that was expected to be scoped to the
current feature branch. Create and configure the repository default branch
first, then rerun the workflow once to populate the cache and a second time to
confirm it restores.

The script performs:

1. artifact build;
2. artifact smoke;
3. archive creation;
4. Linux image build;
5. Linux image smoke;
6. Linux compressed image measurement.

For local Linux image smoke, override the temporary local tag with:

```bash
IMAGE_TAG=local/<service>:<version>-linux-arm64 \
  TARGET_OS=linux ARCH=arm64 \
  scripts/ci-build-service.sh <service> <version>
```

The Edge Runtime workflow does not push these temporary local smoke tags.
Instead, after smoke passes, it pushes each Linux platform image by digest and
then creates the final multi-platform version tag with `docker buildx
imagetools create`.

## Smoke Contract

All service smoke tests are invoked through:

```bash
scripts/smoke.sh <service> --artifact <rootfs>
scripts/smoke.sh <service> --image <image>
```

Artifact smoke behavior:

- Linux artifacts are copied into a temporary slim image and smoked through
  `IMAGE=...`, even on Linux hosts, so validation uses the same minimal base as
  the final image.
- Non-Linux artifacts are smoked directly when the service supports direct
  artifact smoke and the artifact platform matches the host. The service smoke
  receives `ARTIFACT_ROOTFS=...`.
- Non-Linux artifacts without direct smoke support fail clearly.

Service scripts should support direct artifact smoke when we expect macOS
archives to be runnable on the CI host.

## Current Edge Runtime Status

Edge Runtime is the reference implementation:

| Target | Status | Notes |
|---|---|---|
| `linux/arm64` | Supported | Built by native Linux Nix, image produced. |
| `linux/amd64` | Script-supported | Nix expression has Linux x86_64 V8 artifacts, but CI should prove it on a native runner. |
| `darwin/arm64` | Supported | Built by local Nix and smoked directly on macOS. |
| `darwin/amd64` | Out of scope | Dropped until we decide we need Intel macOS artifacts and have a runner to validate them. |

Other services currently keep their Linux Docker artifact builders. macOS
archive support should be added service by service by adding a Nix artifact
backend, then enabling direct artifact smoke for that service.

## Required CI Runner Capabilities

Linux runners:

- Docker with buildx for final image assembly and smoke tests;
- Nix installed with flakes enabled for Nix-backed artifacts;
- target architecture matching `ARCH` for native artifact builds.

macOS runners:

- Nix installed with flakes enabled;
- target architecture matching `ARCH` for direct artifact smoke;
- Xcode command-line tools for Mach-O inspection/signing when the service
  package needs it.

## Submodule Rule

CI must initialize submodules and keep them clean:

```bash
git submodule update --init --recursive
git submodule status --recursive
```

Artifact builders fail if a source submodule is dirty or not at the recipe ref.
