# Host-Native Artifacts

This repository packages Supabase services as self-contained, relocatable
artifacts that a CLI process manager can download and run without Docker. The
artifact rootfs is the source of truth for a service whose Linux image is
derived from it. The CLI owns download, verification, process-compose wiring,
port allocation, and the end-to-end stack contract.

## Artifact and image boundary

The normal path is:

```text
source or pinned upstream input -> native rootfs -> tar.zst + manifest
                                             -> Linux Docker image
```

Nix `dockerTools` packages the prepared rootfs with pinned runtime utilities
and service entry wiring, starting from scratch. Mailpit, Vector, and Imgproxy are external
mirror exceptions: their release path verifies the selected upstream archive or
source snapshot and mirrors the exact OCI image where applicable; it does not
derive a new image from this repository's rootfs.

The release pipeline produces this layout:

```text
artifacts/<service>/<version>/<platform>-<arch>/
├── rootfs/
├── <service>-<version>-<platform>-<arch>.tar.zst
├── <service>-<version>-<platform>-<arch>.sbom.spdx.json
├── SHA256SUMS
└── manifest.json
```

The rootfs is the canonical local build and smoke input. Archives are
distribution products. `SHA256SUMS` covers the archive and SBOM; the manifest
records the source ref or upstream digest, platform, entrypoint/command,
artifact and image sizes, archive/image digests when available, and the SBOM
and license paths.

## Relocation and supported hosts

Portable artifacts must not contain build-machine paths or absolute Nix store
references. The audit must pass, and each manifest records `portable`,
`assumed_host_libs`, and the measured `os_floor` used by the CLI preflight.

Supported targets are `linux-arm64`, `linux-amd64`, and `darwin-arm64`.
Linux artifacts that consume host glibc are measured and gated at glibc 2.35
(Ubuntu 22.04+, Debian 13+, Fedora 40+, or an equivalent host); edge-runtime
and Mailpit use this host-glibc path. Postgres, dynamic Linux PostgREST,
imgproxy, the BEAM services, and the Node services bundle a matched
loader+glibc runtime and are proven in Ubuntu 22.04; their manifests report a
null host floor because the artifact-owned libc defines the runtime floor.
Auth is statically linked and Vector uses musl. macOS artifacts are gated at
macOS 14. `darwin-amd64` has no supported build and smoke target. The floor
check is an execution proof; it does not replace service smoke.

The glibc side-data decision is recorded in
[docs/design/glibc-runtime-side-data.md](docs/design/glibc-runtime-side-data.md):
host-glibc artifacts use host side data, while bundled-glibc artifacts carry
the matching loader/libc and the NSS, gconv, and locale data it needs. Do not
bundle host-libc modules speculatively; bundle independent data proven
necessary, such as the approved BEAM tzdata path.

## Runtime conventions

When a service defines `services/<service>/runtime.env`, image assembly and
host-process smoke apply those values. The CLI must arrange the same profile
when it runs that service; the profile is repository input, not an assertion
that every archive contains `runtime.env`.

Node artifacts bundle the upstream-selected Node runtime under
`node/bin/node`. Their launcher resolves `SUPABASE_NODE`, then the bundled
runtime, so a host-installed Node is not required when the bundle
is present.

Postgres keeps the full major-compatible extension set from the selected
upstream image for local CLI behavior. Its `shared_preload_libraries` follows
the matching `UPSTREAM_IMAGE` policy; the artifact does not substitute a
smaller preload list for upstream behavior.

## Validation and measurements

The release workflow builds and smokes the rootfs, stages the archive,
manifest, SBOM, and checksums as release assets, and derives and smokes the
Linux image for derived-image services. A host-process smoke is the evidence
for native execution; a successful archive upload alone is not an archive
extraction smoke. External mirrors retain their upstream digest and referrer
evidence.

Runtime measurements are service-level smoke observations. Container memory is
the Docker `stats` MemUsage sample; host memory is process-tree RSS, and host
`ps` `%cpu` is an OS-dependent average. These samplers are useful for
regressions within their own path but are not literal RSS equivalents or
directly comparable CPU samples; they do not establish complete Dockerless CLI-stack behavior, workload capacity, or a 25-parallel-stack result.
