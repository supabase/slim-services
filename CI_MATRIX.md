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

`darwin/amd64` is intentionally out of scope for now.

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

The workflow installs Nix with `DeterminateSystems/nix-installer-action` and
writes CI-built misses to GitHub Actions' Nix cache:

- `DeterminateSystems/magic-nix-cache-action` runs after Nix setup. It uses
  GitHub Actions' cache as our private repo cache for store paths that CI has
  to build itself, so later workflow runs can substitute them. Its default
  upstream cache is `https://cache.nixos.org`, so paths fetched from the public
  NixOS cache are not redundantly stored in GitHub Actions cache.
- `DeterminateSystems/flake-checker-action` checks
  `sources/edge-runtime/flake.lock` so we get early visibility into stale or
  unhealthy flake inputs.

With this setup, Nix can read from `cache.nixos.org` and the GitHub-backed
Magic Nix Cache. Store paths missing from those caches are built locally by the
runner and then become available through the GitHub-backed cache on subsequent
workflow runs.

The workflow passes an explicit `nix-fast-build` command template into the Nix
backend:

```bash
nix --extra-experimental-features "nix-command flakes" run \
  "github:Mic92/nix-fast-build/1.5.0" -- \
  --flake "$NIX_INSTALLABLE" \
  --systems "$NIX_SYSTEM" \
  --out-link "$NIX_OUT_LINK" \
  --no-nom \
  --skip-cached
```

The backend fills in `NIX_INSTALLABLE`, `NIX_SYSTEM`, and `NIX_OUT_LINK` after
exporting the clean source tree and applying overlays. `--no-nom` keeps CI logs
compact, and `--skip-cached` avoids rebuilding outputs that are already present
in configured binary caches.

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
