# Edge Runtime Slim Image Report

Self-contained report for the Edge Runtime Linux ARM64 slim-image work.

Last updated: 2026-04-28

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
| Phase 2 artifact archive | `51.7 MiB` |
| Phase 2 rootfs | `160.6 MiB` |
| Phase 2 local image virtual size | `176.4 MiB` |

## Build Contract

- Current backend: Nix.
- Source ref: `v1.73.15`.
- Upstream image: `supabase/edge-runtime:v1.73.15`.
- Runtime base: `gcr.io/distroless/base-debian13:nonroot`.
- Smoke test: `edge-runtime --help`.
- `sources/edge-runtime` is read-only.

## What Changed

- Built from the upstream Nix flake with
  `./sources/edge-runtime#packages.aarch64-linux.edge-runtime`.
- Copied only `/bin/.edge-runtime-wrapped` to
  `/usr/local/bin/edge-runtime` plus `/lib` to `/usr/local/lib`.
- Stripped the executable and shared libraries in an optimizer stage.
- Replaced duplicate ONNX Runtime soname files with symlinks to the real
  versioned library.
- Dropped the BusyBox/shell wrapper from the runtime artifact.
- Set `LD_LIBRARY_PATH=/usr/local/lib` and
  `ORT_DYLIB_PATH=/usr/local/lib/libonnxruntime.so` directly in
  `services/edge-runtime/Dockerfile.slim`.
- Kept the final runtime base at
  `gcr.io/distroless/base-debian13:nonroot`.

## Why This Works

Edge Runtime is a native Rust service with dynamic library dependencies,
including ONNX Runtime. The final artifact follows the portable-bundle pattern:
copy the executable and runtime libs into a controlled rootfs, ensure the
runtime loader sees the bundled libs, and avoid carrying a shell wrapper when
the final image metadata can set the needed environment variables.

## Validation

- Built artifact from `sources/edge-runtime@v1.73.15` with the Nix backend.
- Built final image as `local/edge-runtime:slim-v1.73.15-arm64`.
- Smoke passed with the existing `edge-runtime --help` smoke test.
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
