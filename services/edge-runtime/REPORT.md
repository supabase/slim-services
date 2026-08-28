# Edge Runtime Slim Image Report

Self-contained report for the Edge Runtime Linux ARM64 slim-image work.

Last updated: 2026-04-30

## Summary

Edge Runtime has an adopted phase 2 slim image. The final path uses the upstream
Nix/native build, then prunes the runtime artifact by stripping binaries and
libraries, replacing duplicate ONNX Runtime soname copies with symlinks, and
setting dynamic-library environment variables directly in image metadata.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `supabase/edge-runtime:v1.73.15` | `360.6 MiB` compressed |
| Phase 1 slim image | `85.6 MiB` compressed |
| Current phase 2 slim image, `local/edge-runtime:slim-v1.73.15-arm64` | `60.8 MiB` compressed |
| Phase 2 gain vs phase 1 | `24.8 MiB / 29.0%` |
| Current reduction vs upstream | `299.8 MiB / 83.1%` |
| Phase 2 artifact archive | `37.3 MiB` |
| Phase 2 rootfs | `160.6 MiB` |
| Phase 2 local image virtual size | `176.4 MiB` |

## Build Contract

- Current backend: Nix.
- Source ref: `v1.73.15`.
- Upstream image: `supabase/edge-runtime:v1.73.15`.
- Runtime base: `gcr.io/distroless/base-debian13` (root, empty Config.User).
  Start user and `/root` mode are generated from the digest-pinned upstream
  image (IMAGE_CONTRACT.md).
- Smoke test: `edge-runtime --help`, then start a tiny local `Deno.serve`
  fixture and request it over HTTP.
- The smoke script supports both Docker images via `IMAGE=...` and extracted
  macOS/Linux artifact rootfs directories via `ARTIFACT_ROOTFS=...`.
- `sources/edge-runtime` is read-only.

## What Changed

- Built from the upstream Nix flake with this repo's shared portable Nix
  overlay applied outside the read-only submodule.
- Exported the full Nix-produced portable rootfs: `bin/edge-runtime`,
  `bin/.edge-runtime-wrapped`, and `lib/`.
- Stripped and patched the executable and shared libraries inside Nix.
- Validated the Linux ARM64 artifact by running the shared Nix package in a
  native Linux ARM64 Nix environment, then copying the resulting rootfs into
  the final Distroless Debian 13 ARM64 image.
- Kept the portable shell wrapper in the artifact for extracted-folder use.
- Set `LD_LIBRARY_PATH=/lib` and `ORT_DYLIB_PATH=/lib/libonnxruntime.so`
  directly in `services/edge-runtime/Dockerfile.slim`, where the final image
  enters through `bin/.edge-runtime-wrapped` to avoid a shell dependency.
- Copied artifact `bin/` into `/usr/bin/` in the final image because Debian 13
  Distroless uses a merged `/usr` layout where `/bin` is a symlink.
- Kept the final runtime base at `gcr.io/distroless/base-debian13` (root).

## Why This Works

Edge Runtime is a native Rust service with dynamic library dependencies,
including ONNX Runtime. The final artifact follows the portable-bundle pattern:
copy the executable and runtime libs into a controlled rootfs, ensure the
runtime loader sees the bundled libs, and keep Docker entrypoints shell-free
while preserving the wrapper for extracted portable folders.

## Validation

- Built Linux ARM64 artifact from `sources/edge-runtime@v1.73.15` with the Nix
  backend inside a native Linux ARM64 environment.
- Confirmed the Linux executable and ONNX Runtime shared library are stripped.
- Built final image as
  `local/edge-runtime:slim-v1.73.15-arm64-nix-rootfs`.
- Smoke passed with `edge-runtime --help` and a local function serve/request
  check.
- The same smoke passed against the macOS ARM64 artifact rootfs directly on the
  host.
- Linux portable artifact audit passed inside a Linux ARM64 container.
- Measured `160.6 MiB` rootfs, `37.3 MiB` zstd artifact archive,
  `176.4 MiB` local image virtual size, and `60.8 MiB` gzip-compressed Docker
  archive size.
- `sources/edge-runtime` remained read-only.

## Decision

Adopted. The compressed image gain is `24.8 MiB`, and the changes are localized
to this repo's artifact/runtime packaging.

## Follow-Up

- The remaining large payloads are the Edge Runtime executable and ONNX Runtime
  shared library.
- Further reduction likely requires feature-level build switches, especially an
  optional no-ONNX/local-dev image profile if AI/ONNX support is not always
  needed.

## macOS Portable Artifacts

Added a Darwin artifact path for local development:

- Builder: `TARGET_OS=darwin ARCH=<arch> scripts/build-artifact.sh edge-runtime v1.73.15`.
- Backend: generic Nix artifact builder. The repo-owned portable Nix package
  overlay is copied into a temporary source export, so the submodule remains
  read-only and all closure/rpath/signing work stays in Nix.
- Outputs: `artifacts/edge-runtime/v1.73.15/darwin-<arch>/rootfs`.
- Archive: optional distribution product generated from `rootfs/` with
  `scripts/archive-artifact.sh`.
- Smoke test: `bin/edge-runtime --help`, then a tiny local function served from
  the expanded rootfs.

The first working Darwin artifact was `65.2 MiB` compressed and `193.1 MiB`
unpacked. It still carried a build-time Nix ONNX Runtime rpath, so it was not
portable enough.

The optimized artifact is:

| Metric | Size |
|---|---:|
| macOS ARM64 rootfs | `161.2 MiB` |
| macOS ARM64 archive | `39.9 MiB` |
| Archive gain vs first working Darwin artifact | `25.3 MiB / 38.8%` |
| Rootfs gain vs first working Darwin artifact | `31.9 MiB / 16.5%` |

The Nix package now produces one canonical output:

- `$out`: final portable runtime tree with `bin/` and `lib/`.

The repo copies that output to `artifacts/.../rootfs`. Compressed archives are
derived later from the rootfs when a distributable bundle or compressed-size
measurement is needed.

Shared packaging inside Nix now:

- uses `services/edge-runtime/nix/edge-runtime.nix` instead of patching the
  upstream Nix file in place;
- supports `aarch64-darwin`, `aarch64-linux`, and `x86_64-linux` from the same
  expression;
- intentionally leaves `x86_64-darwin` out of scope until Intel macOS artifacts
  are needed and can be validated on a matching runner;
- completes the transitive dylib closure, including hidden `@rpath` and
  absolute `/nix/store` dependencies such as `libgcc_s.1.1.dylib`;
- rewrites copied Nix store install names to `@rpath/<library>`;
- removes absolute `/nix/store` rpaths from shipped Mach-O files;
- strips local Mach-O symbols with `strip -x`;
- ad-hoc signs every mutated Mach-O file after patching/stripping;
- fails the build if any shipped Mach-O still references `/nix/store`;
- patches Linux ELF rpaths with `patchelf` and audits for remaining Nix store
  references;
- sets platform-specific library paths and `ORT_DYLIB_PATH` in the portable
  wrapper.

Largest remaining Darwin payloads:

| File | Size |
|---|---:|
| `bin/.edge-runtime-wrapped` | `111 MiB` |
| `lib/libopenblas.0.dylib` | `26 MiB` |
| `lib/libonnxruntime.1.24.4.dylib` | `16 MiB` |

Further meaningful reduction likely needs feature-level changes, especially an
optional Edge Runtime build profile without ONNX/OpenBLAS for local development
scenarios that do not need AI inference.

## Footprint Pass 3 (no-AI local-dev profile, 2026-07)

- Bumped `sources/edge-runtime` to `v1.74.2` (CLI-pinned release; upstream
  `nix/` unchanged since v1.73.15, so the portable overlay still applies).
- The portable rootfs now EXCLUDES ONNX Runtime + OpenBLAS by default
  (`withAi ? false` in the package overlay). The binary loads ONNX lazily via
  `ORT_DYLIB_PATH`, so `Supabase.ai` inference fails with a clear dlopen error
  while everything else works; build with `withAi = true` or use the upstream
  image for the AI profile. Rootfs shrank `161.2 -> 128.3 MiB`.
- Added `services/edge-runtime/Dockerfile.artifact`: Docker-hosted Nix build
  for linux targets on non-linux hosts (applies the package overlay and strips
  the submodule `.git` pointer before `nix build`).

| Metric | Value |
|---|---:|
| Image compressed (`docker save \| gzip -9`) | `52.7 MiB` (upstream v1.74.2: `360.6 MiB`) |
| Steady-state RSS (serving the smoke function) | `15.1 MiB` |
| Idle CPU | `0.02 %` |
