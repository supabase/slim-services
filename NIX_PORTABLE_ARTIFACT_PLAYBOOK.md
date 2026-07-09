# Nix Portable Artifact Playbook

This document captures the packaging lessons from the Edge Runtime slim-image
work so other services can reuse the same pattern.

## Goal

Use Nix to produce a minimal, portable runtime rootfs, then build Docker images
by copying that rootfs into the smallest proven base image. The same rootfs
should also be usable for local archive distribution and artifact smoke tests.

## Contract

The canonical build product is an expanded rootfs:

```text
artifacts/<service>/<version>/<platform>-<arch>/
├── rootfs/
├── <service>.tar.zst
└── manifest.json
```

`rootfs/` is the source of truth. Archives are derived distribution products
created later with `scripts/archive-artifact.sh`.

For Nix-backed services, prefer a Nix output that is already the final portable
runtime tree:

```text
$out/
├── bin/
└── lib/
```

The artifact script copies `$out` directly into `artifacts/.../rootfs`.

## What Belongs In Nix

Nix should own build and packaging invariants:

- build the upstream source at the pinned ref;
- copy the service executable or release output;
- copy required runtime shared libraries;
- recursively complete transitive library closure;
- patch rpaths/install names to relative locations;
- set Linux ELF interpreters deliberately;
- strip shipped binaries and shared libraries;
- add thin portable wrappers when extracted-folder execution needs env vars;
- fail the build if shipped files still reference `/nix/store`;
- fail the build if runtime dependencies are unresolved.

Nix should not own behavioral smoke tests that need Docker networking, mounted
fixtures, or HTTP orchestration. Keep those in `services/<service>/smoke.sh`.

## Docker Image Pattern

Final `Dockerfile.slim` files should be artifact-only:

```dockerfile
ARG BASE_IMAGE=gcr.io/distroless/base-debian13:nonroot
FROM ${BASE_IMAGE}
ARG ARTIFACT_ROOT
COPY ${ARTIFACT_ROOT}/bin/ /usr/bin/
COPY ${ARTIFACT_ROOT}/lib/ /lib/
ENTRYPOINT ["/bin/.service-wrapped"]
```

Use `/usr/bin` for copied binaries on Debian 13 Distroless. These images use a
merged `/usr` layout, where `/bin` is a symlink, and copying a real artifact
`bin/` directory over `/` can fail.

Keep the final image shell-free when possible. If the artifact needs a shell
wrapper for extracted-folder use, the Docker image can still enter directly via
the hidden wrapped binary and set simple env vars in image metadata.

## Base Image Selection

Use the smallest base that is proven by smoke tests:

1. `scratch`, when the artifact is static or bundles all system runtime pieces.
2. `gcr.io/distroless/static-debian13`, when no dynamic glibc loader is needed.
3. `gcr.io/distroless/base-debian13`, for dynamically linked glibc services.
4. `gcr.io/distroless/cc-debian13`, when base C++ runtime is needed.
5. Alpine only when musl is explicitly validated or upstream already depends on
   it.

For Edge Runtime we kept `base-debian13:nonroot`. `base-nossl-debian13` worked
for the current smoke and saved a few MiB, but the gain was too small to adopt
without broader TLS coverage.

## Linux Dynamic Linking

If the Linux artifact excludes glibc and the dynamic loader, it is not universal
Linux. It is a glibc-based Linux ARM64 artifact validated against the chosen
Distroless base.

That contract now has a number: shipped ELFs may reference at most
`GLIBC_2.39` (the floor of the shared nixpkgs pin's toolchain output — e.g.
the BEAM services' bundled libsystemd requires exactly 2.39).
`scripts/os-floor.sh --linux` measures it, the portable audit gates it, and
`scripts/floor-check-linux.sh` proves it by executing the launcher inside
ubuntu:24.04. Raising the shared pin can raise this floor silently — the gate
exists to catch exactly that.

For Edge Runtime, we intentionally excluded core system libraries:

```text
ld-linux*
libc*
libdl*
libpthread*
libm*
libresolv*
librt*
```

The binary was patched to use the system loader:

```text
/lib/ld-linux-aarch64.so.1
```

That makes Distroless Debian 13 a sensible host. Running from `scratch` would
require bundling glibc, loader, NSS/DNS files, and CA certificates, then adding
broader DNS/TLS smoke coverage. For Edge Runtime the expected compressed gain
was not worth the extra production responsibility.

## macOS Dynamic Linking

For Darwin artifacts, complete the dylib closure and remove all Nix store
references:

- copy direct and transitive `.dylib` dependencies;
- resolve hidden `@rpath` dependencies;
- rewrite copied Nix store install names to `@rpath/<library>`;
- add `@executable_path/../lib` for binaries;
- add `@loader_path` for libraries;
- delete absolute `/nix/store` rpaths;
- strip local symbols with `strip -x`;
- ad-hoc sign every mutated Mach-O file after patching.

The build should fail if any shipped Mach-O still references `/nix/store`.

## Runtime Wrappers

Portable archives often need a tiny wrapper because `dlopen` dependencies may
not be found through rpath alone.

For Edge Runtime the wrapper sets:

```sh
LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
ORT_DYLIB_PATH="${ORT_DYLIB_PATH:-$LIB_DIR/libonnxruntime.so}"
```

On macOS it uses `DYLD_LIBRARY_PATH` and `libonnxruntime.dylib`.

Keep wrappers thin and generic. Avoid service behavior in wrappers unless the
upstream production launcher requires it.

## Validation Layers

Use three layers of validation:

1. Nix package audit: no unresolved deps, no Nix store leaks, files stripped.
2. Artifact smoke: build a temporary image from `rootfs/` for Linux artifacts;
   run the extracted artifact directly for non-Linux artifacts when the host
   platform matches.
3. Final image smoke: copy the same `rootfs/` into the selected base and run
   the same smoke.

For Edge Runtime the smoke now does:

- `edge-runtime --help`;
- start a tiny local `Deno.serve` fixture;
- request `/smoke` over HTTP and assert the JSON response.

Keep smoke tests small and service-specific. They validate runtime viability,
not full service correctness.

Service smoke scripts should support both contracts when practical:

```bash
IMAGE=local/service:slim services/<service>/smoke.sh
ARTIFACT_ROOTFS=artifacts/<service>/<version>/darwin-arm64/rootfs services/<service>/smoke.sh
```

## Cross-Platform Build Rule

Build Linux ARM64 artifacts inside a Linux ARM64 environment. Do not treat a
Darwin-hosted Nix build as proof of Linux packaging correctness.

The Edge Runtime Linux path uses native Linux Nix:

```bash
TARGET_OS=linux ARCH=arm64 scripts/build-artifact.sh edge-runtime v1.73.15
```

The resulting rootfs is then copied into the final Linux ARM64 image:

```bash
PLATFORM=linux/arm64 scripts/build-image-from-artifact.sh \
  edge-runtime \
  artifacts/edge-runtime/v1.73.15/linux-arm64/rootfs \
  local/edge-runtime:slim-v1.73.15-arm64
```

For CI, prefer the standard one-service orchestration command:

```bash
TARGET_OS=linux ARCH=arm64 scripts/ci-build-service.sh edge-runtime v1.73.15
TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh edge-runtime v1.73.15
```

## Common Pitfalls

- nixpkgs patches some packages to embed absolute Nix store paths inside
  *data*, not just binaries. Worst case found so far: OTP's `disksup.erl` is
  patched to spawn its port shell via the store bash, compiled into
  `disksup.beam` inside a compressed literal chunk — invisible to `strings`,
  `grep`, `otool`, and `ldd`, and it only fails off the build machine (the
  path exists locally). For BEAM artifacts, append
  `-os_mon start_disksup false` to the release `vm.args`; in general, smoke
  the artifact somewhere the build machine's store does not exist (a
  container for Linux, another Mac for darwin) before trusting it.
- `ldd` only sees linked libraries, not every runtime `dlopen` path.
- `patchelf --shrink-rpath` is useful, but still audit afterwards.
- Stripping must happen after patching; otherwise size regressions can be huge.
- Distroless `/bin` and `/lib` symlinks can make `COPY rootfs/ /` fail.
- `--help` is not enough for service confidence; add a tiny real request path.
- A Nix output in the store may be read-only. Normalize permissions before
  exporting it through Docker if local artifact export needs writable files.
- Do not edit `sources/`; copy overlays into temporary build locations.

## When To Use This Pattern

This Nix-first pattern is strongest for native services where we need to own
the runtime shared-library closure. It is less obviously valuable for Node
services, where framework-native standalone outputs and Distroless Node images
may be simpler and smaller enough.

Adopt Nix when it improves reproducibility, closure control, or portability.
Do not force it when Docker source builds are clearer.
