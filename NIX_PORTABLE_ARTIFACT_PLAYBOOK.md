# Nix build architecture

The root flake is the build interface. Ordinary Nix functions define service
builds, portable runtimes, archives, and images. Release scripts select inputs,
invoke those outputs, run real service smokes, and publish the tested products.

```text
upstream release selection
          |
          v
exact source + tool versions + dependency hashes
          |
          v
service derivation -> portable runtime -> distribution archive
                                      -> Docker-compatible image
```

## Code ownership

- `flake.nix` declares shared inputs and public outputs; `flake.lock` pins them.
- `nix/packages.nix` selects the requested service and its package arguments.
- `nix/packages/` contains Auth, Node, and Darwin PostgREST packages.
- `services/<service>/nix/` contains the larger BEAM, Edge Runtime, Imgproxy,
  and Postgres packages and their upstream-specific adapters.
- `nix/portable-*/` contains runtime-family relocation helpers and launchers.
- `nix/archive.nix` creates deterministic zstd archives with pinned tools.
- `nix/images/` defines image files, utilities, and container configuration.
- `scripts/build-artifact-from-nix.sh` resolves a release and exports its runtime.
- `scripts/nix.sh` owns the common flake invocation and dependency hash probes.

Package functions take source, version, dependencies, and hashes explicitly.
They do not read build parameters from the environment during evaluation.
Shared nixpkgs and runtime-definition pins remain distinct where compatibility
requires it. Postgres and Edge Runtime retain the selected upstream release's
own locked dependencies; updating the root lock does not replace those graphs.

The root flake advertises Postgres's public binary cache through `nixConfig`.
Release commands accept that configuration explicitly; a cache miss or an
invocation that opts out still falls back to a source build. On multi-user Nix
installations, configure the same `extra-substituters` and
`extra-trusted-public-keys` in the daemon's `nix.conf` so builds can use the
cache. Do not add users to `trusted-users` for this purpose.

## Automatic releases

The hourly poller and `.github/service-release-sources.json` remain the release
policy. The poller enumerates eligible versions at or above each release floor,
skips published/in-flight releases, and dispatches `service-release.yml` with
the selected service and version. No lock-file edit is required for a new
upstream service release.

The build job checks out the exact source commit and creates a temporary
`release` input containing:

```text
release.json   Service, version, source provenance, dependency hashes,
               and upstream-declared tool versions where applicable.
source/        Clean upstream source export, without injected package files.
```

For nested upstream flakes, the same source also overrides the root flake's
`upstream` input. The upstream lock supplies that release's dependency graph.
`--no-write-lock-file` keeps per-run release selection out of the repository's
shared toolchain lock.

Dependency discovery runs ordered fixed-output probes. Each reported content
hash is added to the release input; a network/compiler failure without a hash
fails the release. The final runtime build consumes the resolved hashes with
pure evaluation. The manifest records the release input and derived hashes.
Flake locking and language dependency hashes protect different inputs: the
flake lock does not replace npm, pnpm, Cargo, or Mix dependency locking.

## Build outputs

The normal service entry point remains:

```sh
TARGET_OS=linux ARCH=arm64 scripts/build-artifact.sh realtime v2.134.6
```

It verifies the selected source checkout, resolves missing dependency hashes,
and builds `packages.<system>.runtime` through the root flake. Available Nix
systems are `aarch64-linux`, `x86_64-linux`, and `aarch64-darwin`. Builds for a
foreign system require a matching configured Nix builder; service-specific
Docker build runners are no longer a second build implementation.

Given a resolved release input, the underlying interface is:

```sh
nix build .#runtime --override-input release path:/absolute/release-input --no-write-lock-file
```

Archives and images can also be produced from an already audited rootfs:

```sh
scripts/archive-artifact.sh artifacts/realtime/v2.134.6/linux-arm64/rootfs
scripts/build-image-from-artifact.sh realtime artifacts/realtime/v2.134.6/linux-arm64/rootfs local/realtime:slim
```

The packaging scripts pass that rootfs as an explicit flake input. Image
assembly uses pinned Nix packages; Docker is used afterward to load, smoke, and
publish the image. Upstream mirror services retain their separate provenance
contract: Mailpit and Vector consume verified upstream archives, Imgproxy
builds its native package, and their images remain exact upstream mirrors.
Linux PostgREST retains its verified upstream-image extraction path.

## Portability boundary

Nix owns service compilation, dependency installation, runtime closure
completion, relocation, stripping, and pruning. A portable runtime must work
without the build machine's `/nix/store`. Linux launchers and runtime side data
must follow the matched-loader/glibc contract in
[the runtime side-data decision](docs/design/glibc-runtime-side-data.md).

macOS exported Mach-O signatures are verified and, when necessary, repaired
with the host's system signer before auditing and packaging. This explicit
host operation is retained because a signature made in the build environment
can fail after export. Both archive and image packaging consume the final
exported artifact.

Keep runtime-family helpers separate when their requirements differ. OTP
releases, Node applications, and PostgreSQL extension trees have different
closure and launcher rules; sharing a package interface does not require a
universal relocation framework.

## Verification

Run host fixture scripts locally. Use `service-release.yml` with
`validation_only=true` and `force=true` on the branch for real artifact/image
builds and service smokes. The workflow tests all three supported targets and
uploads inspection artifacts without replacing published releases.

Preserve every unpublished version above its release floor. A recipe change
must exercise the affected backlog; linkage or platform changes also require
the supported target matrix. Successful Nix evaluation alone is not runtime
proof. Use actual database/API/service requests and the host-floor execution
checks described in [CI_MATRIX.md](CI_MATRIX.md).
