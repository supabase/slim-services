# Vector 0.53.0 Release Report

Pre-publication verification record for the Vector upstream-release artifact
and exact OCI mirror. This report describes the pinned `0.53.0` input; the
release is intentionally not included in the generated README size/runtime
tables until native release and public-image gates complete.

## Primary-source pins and licensing

- Upstream source repository: [`vectordotdev/vector`](https://github.com/vectordotdev/vector).
- Upstream release tag: `v0.53.0` (the public release tag for manual version
  input `0.53.0`).
- Upstream archive assets are consumed without a source rebuild and are
  verified before extraction:

| Target | Published asset | SHA-256 |
| --- | --- | --- |
| `darwin-arm64` | `vector-0.53.0-arm64-apple-darwin.tar.gz` | `a42c59263abbbcae012a2c0f73c3e916dc220305b2a223725f2324ae18efcd80` |
| `linux-amd64` | `vector-0.53.0-x86_64-unknown-linux-musl.tar.gz` | `799d1d1502c746d767172c92f31fd6424ea7879e3dcab5826b67717799d4f306` |
| `linux-arm64` | `vector-0.53.0-aarch64-unknown-linux-musl.tar.gz` | `f525fd7e66307ef069ad4359a0f889fba402b0b8bb3ca75198143f567021c5ca` |

Vector is licensed under MPL-2.0. The normalized archive preserves the
upstream `LICENSE`, `LICENSE-3rdparty.csv`, and dependency license texts under
`share/licenses/vector/`; the repository notice is recorded in
[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).

## Normalized artifact and portability contract

The recipe uses `ARTIFACT_BACKEND=upstream-archive`, maps only the pinned
allowlist, marks the result portable, and invokes `/bin/vector` with no
entrypoint. The Darwin artifact inspected for this report has this layout:

```text
rootfs/
├── bin/vector
├── share/doc/vector/README.md
├── share/doc/vector/config/              # upstream config/examples reference files
└── share/licenses/vector/                # MPL-2.0 and dependency notices
```

Linux normalization additionally retains the upstream `NOTICE` and systemd
reference files as documentation; no service-manager file is installed as
active host configuration. The executable is copied byte-for-byte from the
verified archive. Linux release binaries are statically linked musl builds;
the Darwin binary relies only on the declared Apple system libraries and
frameworks. The generated Darwin manifest records a measured macOS floor of
`11.0` and no unresolved portability references.

## Current darwin-arm64 evidence

Evidence below comes from the ignored generated output at
`artifacts/vector/0.53.0/darwin-arm64/` (it is not committed):

| Item | Value |
| --- | ---: |
| Platform | `darwin/arm64` |
| Rootfs | `114.3 MiB` |
| Normalized archive | `vector-0.53.0-darwin-arm64.tar.zst`, `32.1 MiB` |
| Archive SHA-256 | `1385a3c09950d1bb37feda92bad25df122fe504f5e8bfea346d555142a3a11f3` |
| SPDX-2.3 SBOM SHA-256 | `384e143d4856a92ea9323b0d15919594df6f1e2f7bd0ed9c485fac3872f50e7a` |
| Manifest runtime RSS | `22.0 MiB` |
| Manifest idle CPU | `0.00%` |
| Manifest runtime samples | `3` after a `10 s` settle |
| Measured macOS floor | `11.0` |

The manifest's normalized member provenance includes the byte-identical
`bin/vector` digest
`e4094bb8a9ee4f63242b5c7d47fb417411cf5170f79a3e4e3d529c126a152a83`; license
and documentation member digests are recorded alongside it in the manifest.
The generated `SHA256SUMS` covers the archive and SBOM. A fresh native smoke
rerun measured `28.4 MiB` RSS and `0.0%` idle CPU; the difference from the
generated manifest is expected sampling variance, not a layout change.

## Exact OCI mirror input

The mirror policy pins the Alpine image independently from the native archive:

- Source tag: `docker.io/timberio/vector:0.53.0-alpine`.
- OCI index digest: `sha256:ca92d617e905953c3f852e7e88061f7039460e733522e3f0c21bc6ae946b2558`.
- Destination tag: `ghcr.io/supabase/cli/vector:0.53.0`.

Required runtime platform descriptors are:

| Platform | Digest |
| --- | --- |
| `linux/amd64` | `sha256:7a74872eb7791f65357b200813bcf613c8dedcac561b4f1a68f9d290f6e6a40c` |
| `linux/arm64` | `sha256:d2d5381f69b885c1b10d396623bf8d5ce825bcb8f8efcdb14a3154223c13b3b7` |

The pinned OCI index also carries these embedded attestation descriptors,
which the verifier requires to survive the copy:

```text
linux/amd64  sha256:1396baba9135c2c0708265fd2e958a4219645ba9588230fbb90bb63699695a74
linux/arm64  sha256:ed65ba7b8e4d7fe0b9ea99f219ff2a3eacd07572f3b352eae2bd6b58266a640e
linux/arm/v7 sha256:fc62606d6512d313f4d107b963451aafa9350cd19182eec84ab0785c8b842222
linux/arm/v6 sha256:bb69f3cf81937d19c869b83324df833719c4620ced6a4405b21e38e2e16b9c5c
```

Publication uses `regctl image copy --digest-tags --referrers` from the
immutable source reference. `scripts/verify-oci-mirror.py` compares raw index
bytes, required platform digests, and embedded attestations; the mirror helper
also compares the complete external referrer digest tree and proves anonymous
destination resolution, pull, and the service smoke. No local GHCR mirror
publish was performed for this report.

## Smoke coverage

The Vector smoke validates the same contract in artifact and image modes: it
validates a file source → VRL remap → file sink pipeline, checks exactly-once
transformed output, stops and restarts against the same state directory, and
records runtime metrics.

Commands passed on the current Darwin host:

```text
ARTIFACT_ROOTFS=artifacts/vector/0.53.0/darwin-arm64/rootfs \
  services/vector/test-smoke.sh
IMAGE=docker.io/timberio/vector:0.53.0-alpine services/vector/smoke.sh
```

## Verification record

The following repository checks are required for this registration and were
run or are the exact CI commands for the release path:

```text
scripts/poll-service-releases.sh --validate-config
scripts/test-upstream-release.sh
scripts/test-extract-upstream-archive.sh
scripts/test-upstream-artifact.sh
scripts/test-oci-mirror.sh
scripts/test-upstream-runtime.sh
scripts/test-license-compliance.sh
while IFS= read -r script; do bash -n "$script"; done < <(find scripts services -type f -name '*.sh' -print | sort)
shellcheck --severity=warning --exclude=SC2034,SC2154,SC3045 $(find scripts services -type f -name '*.sh' -print | sort)
```

The focused routing checks prove that `poll=false` excludes Vector from the
poller, manual dispatch accepts `vector`/`0.53.0`, policy resolution uses
upstream `v0.53.0`, and mirror smoke selection is driven by each recipe's
`IMAGE_RELEASE_MODE=mirror` (Mailpit remains covered by the same route).

## Post-merge gates and open work

CLI-2139 remains open until all of the following are recorded after merge:

1. Dispatch `service=vector`, `version=0.53.0`, and `force=false`; attach the
   GitHub release URL, native archive manifests/checksums/SBOMs, and published
   GHCR index/platform digests.
2. Prove anonymous `ghcr.io/supabase/cli/vector:0.53.0` resolution, pull, and
   Vector image smoke with empty local registry credentials.
3. Complete later CLI integration (download/verify and process-compose stack
   lifecycle acceptance) before closing the CLI work.

