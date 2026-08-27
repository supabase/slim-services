# Auth Slim Image Report

Self-contained report for the Auth Linux ARM64 slim-image work.

Last updated: 2026-04-29

## Summary

Auth keeps its phase 1 slim image as the current best image. The service builds
as a static Go executable with embedded migrations, so the first working
artifact runs from `scratch` with only the binary, the `gotrue` compatibility
symlink, CA certificates, and minimal user metadata.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `supabase/gotrue:v2.189.0` | `23.7 MiB` compressed |
| Phase 1 slim image, `local/auth:slim-v2.189.0-arm64` | `10.2 MiB` compressed |
| Current phase 2 slim image, `local/auth:slim-v2.189.0-arm64` | `10.2 MiB` compressed |
| Current reduction vs upstream | `13.5 MiB / 57.0%` |
| Current artifact archive | `10.3 MiB` |
| Current rootfs | `28.3 MiB` |
| Current local image virtual size | `28.1 MiB` |
| Upstream local image virtual size | `48.9 MiB` |

## Build Contract

- Current backend: source submodule build.
- Source ref: `v2.189.0`.
- Upstream image: `supabase/gotrue:v2.189.0`.
- Runtime base: `scratch`.
- Entrypoint: `/usr/local/bin/auth`.
- Smoke test: `/health` returns `200` against a temporary Postgres.
- `sources/auth` is read-only.

## Phase 1 Packaging

- Builds the upstream Go service with `CGO_ENABLED=0`.
- Uses `-trimpath`, `-buildvcs=false`, and stripped linker flags.
- Copies `/usr/local/bin/auth` into the artifact and keeps `/usr/local/bin/gotrue`
  as a compatibility symlink.
- Copies the CA certificate bundle for outbound OAuth/OIDC/SMTP/TLS use cases.
- Does not copy the upstream `migrations/` directory because migrations are
  embedded in the executable in `v2.189.0`.
- Runs the final image as UID/GID `1000:1000` from `scratch`.

## Phase 2 Decision

Not adopted. Phase 1 already runs from `scratch` and the rootfs is only the
static executable, `gotrue` symlink, CA bundle, and minimal user metadata. Any
phase 2 work would be binary-level experimentation with limited expected gain,
so the current phase 2 numbers repeat the phase 1 numbers.

## Validation

- Added `sources/auth` at `v2.189.0`.
- Built source artifact from `sources/auth@v2.189.0`.
- Built final image as `local/auth:slim-v2.189.0-arm64`.
- Verified the binary is a stripped, statically linked Linux ARM64 executable.
- Artifact-mode smoke passed.
- Final image smoke passed with `/health` against a temporary Postgres.
- Smoke creates the `auth` schema before startup because Auth migrations expect
  the schema to already exist.
- `sources/auth` remained clean.

## Decision

Adopted. Auth is already compact upstream, but the `scratch` image still saves
`13.5 MiB` compressed while keeping the production executable and embedded
migrations intact. No separate phase 2 optimization is worth carrying for now.

## Footprint Pass 3 (runtime profile, 2026-07)

- Bumped `sources/auth` to `v2.192.0` (CLI-pinned release); builder image bumped
  to `golang:1.25.11-alpine3.23` (go.mod toolchain floor) and the artifact build
  now copies `internal/forks/` before `go mod download` (local `godotenv` fork
  replace directive introduced in v2.190.0).
- Added `runtime.env` low-footprint local-dev defaults, baked as image ENV and
  overridable at `docker run -e`: `GOMEMLIMIT=64MiB`, `GOGC=50`, `GOMAXPROCS=2`,
  `GOTRUE_DB_MAX_POOL_SIZE=2` (client pool holds server-side postgres backends).
- Smoke now records steady-state runtime metrics into `manifest.json`.

| Metric | Value |
|---|---:|
| Image compressed (`docker save \| gzip -9`) | `11.2 MiB` |
| Steady-state RSS (idle, after /health) | `24.8 MiB` |
| Idle CPU | `0.58 %` |

## Host-Native darwin-arm64 Artifact (2026-07)

Auth is the first service on the host-native contract (HOST_NATIVE_PLAN.md):
`services/auth/build-host.sh` cross-compiles the pinned submodule with the Go
version declared by upstream `go.mod` (`CGO_ENABLED=0 GOOS=darwin
GOARCH=arm64`, same flags as upstream) — no Docker in the build or smoke path
for the service.

- Layout: `rootfs/bin/auth` + `bin/gotrue` symlink. No CA bundle (Go uses the
  macOS system trust store) and no `migrations/` directory (embedded via
  `go:embed` in `main.go` since v2.189.0). The CLI's current
  `~/.supabase/bin/auth/<version>/darwin-arm64/` layout ships a `migrations/`
  directory and bare `auth`/`gotrue` at the platform root; the embedded
  migrations make the directory redundant for these versions.
- `manifest.json`: `portable: true`, assumed host libs = libSystem + system
  frameworks (pure-Go darwin binaries still link libSystem).
- Smoke: host process against the harness postgres with `runtime.env` applied,
  `/health` 200; re-run from an untarred archive in a scratch directory to
  prove relocatability. `scripts/audit-portable-artifact.sh --darwin` clean.

| Metric | Value |
|---|---:|
| Archive (`auth-v2.192.0-darwin-arm64.tar.zst`) | `9.4 MiB` |
| rootfs | `33.5 MiB` |
| Steady-state RSS (host process, idle) | `29.3 MiB` |
| Idle CPU | `0.0 %` |

### Native-first convergence (2026-07)

`build-host.sh` now builds the Linux artifacts too (Go cross-compiles from
any host), so every target shares the `bin/auth` layout, and
`Dockerfile.slim` derives the scratch image from the artifact (an alpine
stage supplies the CA bundle, passwd/group, and the `gotrue` symlink;
entrypoint unchanged). The docker-source builder is gone. linux-arm64
verified: derived image smoke green (`/health` 200, RSS 8.0 MiB, 11.4 MiB
gzip ≈ before); linux-amd64 artifact builds a static x86-64 ELF.

## Image HEALTHCHECK (2026-08)

The scratch image cannot run CMD-SHELL healthchecks, so slim `supabase
start` reported auth ready on `Running` (supabase/slim-services#280). The image
now bakes an exec-form `HEALTHCHECK` backed by `bin/auth-healthcheck`, a
static stdlib-only Go probe (`services/auth/healthcheck/`, cross-compiled in
a Dockerfile stage from the build platform): gotrue has no health
subcommand, and the image has no shell to fetch `/health` otherwise. The
probe resolves the port with gotrue's own `GOTRUE_API_PORT` → `PORT`
precedence, falling back to the image's baked `ENV PORT=9999` (gotrue's
built-in default is 8081, so the image bakes the port its EXPOSE and the
CLI already assume). The image smoke runs without injecting a port env and
waits for `docker inspect` to report `healthy`, pinning the baked-port
contract.
