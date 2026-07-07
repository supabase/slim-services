# PostgREST Slim Image Report

Self-contained report for the PostgREST Linux ARM64 slim-image work.

Last updated: 2026-04-28

## Summary

The stable `v14.10` PostgREST ARM64 image is now represented by a `scratch`
runtime image built from the upstream Ubuntu ARM64 release archive plus the
exact dynamic library closure it needs. Phase 2 is intentionally the same as
phase 1 for stable `v14.10` because the runtime base is already `scratch`.

The next major win depends on consuming a stable upstream static ARM64
PostgREST artifact once it is published.

## Measurements

| Metric | Size |
|---|---:|
| Upstream ARM64 image, `postgrest/postgrest:v14.10` | `126.0 MiB` compressed |
| Current slim image, `local/postgrest:slim-v14.10-arm64` | `21.2 MiB` compressed |
| Reduction vs upstream | `104.8 MiB / 83.2%` |
| Phase 2 delta | `0.0 MiB / 0.0%` |

## Build Contract

- Current backend: release archive plus runtime dependency bundling.
- Source ref: `v14.10`.
- Upstream image: `postgrest/postgrest:v14.10`.
- Runtime base: `scratch`.
- Smoke test: `/` returns `200` against a temporary Postgres container.
- Stable source/service code is not modified.

## What We Built

The working stable artifact downloads the upstream
`postgrest-v14.10-ubuntu-aarch64.tar.xz` release archive and copies the
`postgrest` binary to `/bin/postgrest`.

A raw binary-only `scratch` image builds, but fails at startup with:

```text
exec /bin/postgrest: no such file or directory
```

That is the expected symptom for a dynamically linked binary whose ELF
interpreter is missing. The stable ARM64 upstream release expects
`/lib/ld-linux-aarch64.so.1`.

The passing image keeps `scratch` and bundles the exact Ubuntu 24.04 runtime
closure reported by `ldd`: glibc loader/libc, `libpq`, OpenSSL, zlib, GMP,
Kerberos/LDAP/SASL/GnuTLS transitives, CA certificates, and `nsswitch.conf`.
This removes the general Ubuntu package-manager and filesystem baggage while
preserving stable upstream behavior.

## Static ARM64 Investigation

We tried to align with the upstream Nix/static route. Cachix is configured and
does substitute the current upstream static ARM64 toolchain, but the local
`v14.10` static build remained too slow for this pass.

We also validated upstream PR #4193 artifacts from GitHub Actions:

- Binary artifact: `postgrest-linux-static-aarch64`.
- Docker artifact: `postgrest-docker-aarch64`.
- The binary reports `PostgREST 15 (pre-release)`, so it is not a stable
  `v14.10` replacement.
- `file` reports a statically linked, stripped ARM64 ELF.
- `ldd` reports `not a dynamic executable`.
- Binary/rootfs size: `18.8 MiB`.
- Recompressed artifact archive: `5.9 MiB`.
- Smoke passed for both the rebuilt `scratch` image and the downloaded upstream
  Docker artifact image.

## Decision

- Keep stable `v14.10` on the current bundled `scratch` artifact.
- Record phase 2 as the same `21.2 MiB` image because there is no extra local
  optimization to apply while preserving stable `v14.10`.
- Once a stable static ARM64 artifact lands upstream, switch to copying only
  `/bin/postgrest` into `scratch`; that should bring the ARM64 image much closer
  to the tiny upstream AMD64/static packaging shape.

## Validation

- Slim image smoke passed against temporary Postgres.
- Static PR artifact smoke passed separately, but was not adopted for stable
  `v14.10`.

## Follow-Up

- Watch for a stable upstream static ARM64 PostgREST release artifact.
- Revisit Nix/source static build only if we need to produce the static binary
  ourselves before upstream publishes it.

## Footprint Pass 3 (runtime profile, 2026-07)

- Bumped to `v14.14` (CLI-pinned release); image extraction from
  `postgrest/postgrest:v14.14` with the same ELF closure bundling.
- Added `runtime.env` baked as image ENV (overridable): `PGRST_DB_POOL=2` —
  each pooled connection holds a server-side postgres backend, so the upstream
  default of 10 costs ~50-150 MiB inside postgres per stack.
- Smoke now records steady-state runtime metrics into `manifest.json`.

| Metric | Value |
|---|---:|
| Image compressed (`docker save \| gzip -9`) | `20.3 MiB` |
| Steady-state RSS (idle) | `29.4 MiB` |
| Idle CPU | `0.13 %` |
