# Vector external-release report (historical 0.53.0 evidence)

Pre-publication verification record for the Vector upstream-release artifact
and exact OCI mirror. This report describes the pinned `0.53.0` input; the
release is intentionally not included in the generated README size/runtime
tables until native release and public-image gates complete.

## Primary-source pins and licensing

- Upstream source repository: [`vectordotdev/vector`](https://github.com/vectordotdev/vector).
- Manual release input is resolved dynamically from the versionless
  `external-release.json` descriptor. `0.53.0` below is retained as historical
  evidence from the last compatibility check, not as a supported-version gate;
  the descriptor adds the `v` GitHub prefix and `-alpine` OCI suffix.
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

## Pre-merge native matrix evidence

The [native matrix workflow run 31796344933](https://github.com/supabase/slim-services/actions/runs/31796344933)
was run at the exact head `53c2b52e73509f536ed4e2ff3248092e3a13e4c2`. It built
and exercised all three verified upstream archives directly on their native
hosts; cache reuse was bypassed. Each target ran the same file source → VRL
transform → file sink flow, proved exactly-once transformed output across a
stop/restart using the same state directory, cleaned up its temporary state,
and collected runtime samples.

| Target | Normalized archive SHA-256 | SPDX-2.3 SBOM SHA-256 | `bin/vector` SHA-256 | RSS | Idle CPU | Manifest portability metadata |
| --- | --- | --- | --- | ---: | ---: | --- |
| `darwin/arm64` | `d8508190c546279efa6dcdd2254f215d81ee23aabc25505260c799c5af82f4e7` | `384e143d4856a92ea9323b0d15919594df6f1e2f7bd0ed9c485fac3872f50e7a` | `e4094bb8a9ee4f63242b5c7d47fb417411cf5170f79a3e4e3d529c126a152a83` | `25.7 MiB` | `0.0%` | `libc=null`; macOS floor `11.0` |
| `linux/amd64` | `1318ccf98ee8e7ab3d77b86d05832c5984c4b80257863fb61e7e57c303486920` | `1473b9dc858893d334077371fc1425834e71472c94f22897f876bee27b717f30` | `30bd4693f0a2631792f7ccd7c7a9ca8c3e0b0052cd9dc59c8c2e3f7fceb537f4` | `62.4 MiB` | `0.0%` | `libc=musl`; assumed host libs `[]`; `os_floor.kind=glibc`, floor `null`, `bundled_glibc=false` |
| `linux/arm64` | `a9f61f66fef77cc91e19f91a7f4c0bd34f628d4271dd37c51e022690805bf229` | `0b1b596c14d565ad4146a38701840ca649b93076b3bc5deb3a1548573adb1e00` | `8fb5e2c9fbe424d11d278330f1a250683b993b3edf69605a6ac31252009685fc` | `27.2 MiB` | `0.0%` | `libc=musl`; assumed host libs `[]`; `os_floor.kind=glibc`, floor `null`, `bundled_glibc=false` |

For Linux, `libc=musl` records the verified static-musl archive metadata.
`os_floor.kind=glibc` is the scanner's fixed contract for reporting a
GLIBC-symbol floor; it is not a claim about the binary's linkage. The null
floor and `bundled_glibc=false` correctly record that these static-musl
binaries neither require host GLIBC symbols nor ship a bundled glibc pair.
For each row, the run's `SHA256SUMS` covers that target's normalized archive
and SPDX-2.3 SBOM. Each manifest records normalized-member provenance for the
byte-identical `bin/vector` plus the license and documentation files and their
digests.

## Exact OCI mirror input

At attempt time, the plan job resolves the GitHub release and independent OCI
tag once, then uploads one immutable snapshot and sidecar. Every native build,
mirror, and release consumer downloads and verifies those exact bytes before
loading its recipe. The v0.53.0 values below remain historical evidence.

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
also compares the complete external referrer digest tree. The real pinned
source-image smoke is recorded separately below. No local GHCR mirror publish
was performed for this report.

## Smoke coverage

The pre-merge native matrix above validates the same contract for every
target in direct-host mode (not a Docker image): file source → VRL transform →
file sink, exactly-once transformed output across restart, temporary-state
cleanup, and runtime sampling with the build cache bypassed. The OCI mirror
smoke remains a separate gate against the pinned Alpine image. The pinned
source-image smoke passed locally on the current Darwin host:

```text
IMAGE=docker.io/timberio/vector:0.53.0-alpine services/vector/smoke.sh
```

The destination GHCR mirror smoke and anonymous pull remain post-merge gates,
as listed below.

The repository check `scripts/test-oci-mirror.sh` is fixture-based routing and
security verification for the mirror helpers; it is not a real Vector image
smoke and does not replace the command above.

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
