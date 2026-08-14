# Mailpit external-release report (historical v1.30.2 evidence)

Pre-publication verification record for the Mailpit upstream-release artifact
and exact OCI mirror. Mailpit is not included in the generated README size or
runtime tables until its release has been published and its release metadata
has been reconciled.

## Upstream and licensing

- Upstream repository: [`axllent/mailpit`](https://github.com/axllent/mailpit).
- Manual release input is resolved dynamically from the versionless
  `external-release.json` descriptor. `v1.30.2` below is retained as historical
  evidence from the last compatibility check, not as a supported-version gate.
- License: MIT. The normalized archive carries the upstream `LICENSE` file at
  `share/licenses/mailpit/LICENSE`; the repository-level notice is recorded in
  [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md).
- The source archive is repackaged without a source rebuild. The normalized
  executable is byte-identical to the extracted upstream executable.

### Native release assets

The historical v1.30.2 snapshot produced from the descriptor pinned these exact
assets and SHA-256 values:

| Target | Published asset | SHA-256 |
| --- | --- | --- |
| `darwin-arm64` | `mailpit-darwin-arm64.tar.gz` | `05b92a4b804c34b0f6e665a482a1141be64256f500ecf23a204c2084a27a248b` |
| `linux-amd64` | `mailpit-linux-amd64.tar.gz` | `63b113aa9748adf7091b649ebe02693f99a459000cbe415faa6679f4b39f82cf` |
| `linux-arm64` | `mailpit-linux-arm64.tar.gz` | `b159574f32e527f34624e5683f79859258360179268a8fac0f3030f74ca6bb96` |

Linux artifacts are glibc artifacts; the CLI host requirement is the glibc
family (with the repository Linux floor policy applied by the portable audit).
The macOS artifact uses the host `libSystem`/system frameworks and has a
measured macOS floor of 12.0.

## Normalized artifact contract

Every target is normalized to the common layout:

```text
rootfs/
├── bin/mailpit
├── share/doc/mailpit/README.md
└── share/licenses/mailpit/LICENSE
```

The recipe invokes `/bin/mailpit`, marks the artifact portable, and records
`runtime_requires=glibc` for the Linux contract. No extra shell, database
directory, or generated wrapper is added; Mailpit's runtime profile supplies
bind addresses, POP3 authentication, reverse-DNS behavior, and SQLite state
path at invocation time.

## Docker input and exact mirror

At attempt time, the plan job resolves GitHub release assets and the independent
Mailpit OCI tag once, writes the immutable snapshot and sidecar, and all build,
mirror, and release jobs verify that artifact before recipe loading. The values
below are preserved only to document the prior v1.30.2 verification.

The source image policy pins:

- Source tag: `docker.io/axllent/mailpit:v1.30.2`.
- OCI index: `sha256:37a38e48e9338cd7e89dfeb487f37b02ebfcd9cb23111bed2d345e79d37d6dd6`.
- `linux/amd64`: `sha256:f0b0ed33c8cf53aac0dd004abbe245c83420a7ae44914e25178f7791dec5723a`.
- `linux/arm64`: `sha256:60ae914dde3ad75aaf153c65cdf4a4e76cb2b89abc3720f37340c2cc8271a2f7`.

The release destination is
`ghcr.io/supabase/cli/mailpit:v1.30.2`. Mirror publication uses the exact
immutable source reference and runs:

```text
regctl image copy --digest-tags --referrers \
  docker.io/axllent/mailpit:v1.30.2@sha256:37a38e48e9338cd7e89dfeb487f37b02ebfcd9cb23111bed2d345e79d37d6dd6 \
  ghcr.io/supabase/cli/mailpit:v1.30.2
```

The verifier compares raw source and destination index bytes, required platform
descriptors, and embedded attestations. It also queries both external referrer
trees with `regctl artifact tree --digest-tags` and requires the sorted digest
sets to match; referrer-tree query errors fail closed. The destination index and
platform descriptors therefore remain digest-identical to upstream rather than
being rebuilt or re-tagged into a different image.

## Smoke and local darwin-arm64 evidence

The full current-platform command passed:

```text
TARGET_OS=darwin ARCH=arm64 scripts/ci-build-service.sh mailpit v1.30.2
```

That run downloaded and verified the pinned `mailpit-darwin-arm64.tar.gz`,
normalized it, passed the portable audit, and ran the artifact smoke before and
after restart. The smoke exercises:

- SMTP submission with a unique RFC 5322 `Message-ID`;
- UI `/` and API `/api/v1/messages` HTTP checks;
- authenticated POP3 `LIST`/`RETR` and retrieval of the same message;
- SQLite persistence across stop/start, with the second check requiring the
  pre-existing message rather than resending it;
- independent HTTP/SMTP/POP3 port allocation and rebind after restart;
- host runtime RSS/idle-CPU sampling.

The deletion regression (`services/mailpit/test-smoke-persistence.sh`) also
passed: deleting the SQLite database, WAL, and SHM files causes the
existing-message check to fail instead of silently resending.

The generated darwin-arm64 evidence is:

| Item | Value |
| --- | ---: |
| Rootfs | `24.9 MiB` |
| Archive (`mailpit-v1.30.2-darwin-arm64.tar.zst`) | `7.7 MiB` |
| Host RSS | `26.4 MiB` |
| Idle CPU | `0.0%` |
| macOS floor | `12.0` |

Manifest/archive inspection recorded these digests:

```text
bin/mailpit                         5a10eaa5b5b371bba6232e1568bcf967819cf592de7f10806cd63b203c41c923
share/licenses/mailpit/LICENSE     9dade1b3ace5dd6c36ca58eef466ae7dd9afe52bfb978deffa44645f6f0a2aa9
share/doc/mailpit/README.md         21e25814c9502db02d110e32f50c9a3a2a345e1da01f74bad552c5ea136a4889
normalized tar.zst                  d9b9325e451490cd554f82eb73ab35a85c3f5d9fd81624848cfa1f1da4f91789
SPDX-2.3 SBOM                       5e73a15bec01bb84eaa40a706ed2f9eff3fe733b1c01cf5c4cabb72142fbc736
```

The generated manifest, SPDX SBOM, `SHA256SUMS`, upstream license, and
upstream README were inspected. The smoke cleanup left no Mailpit process or
test port listener behind.

## Publication gate and follow-up

No GHCR image or GitHub release was published during this verification. The
mirror helper has an anonymous check that uses empty `REGCTL_CONFIG` and
`DOCKER_CONFIG` directories, but an anonymous resolution/pull/smoke of the
future public destination is not evidence available in this worktree.

After merge, dispatch the `mailpit` `v1.30.2` release workflow and record on
CLI-2138:

1. the GitHub release URL;
2. GHCR index and platform digests;
3. anonymous destination resolution, pull, and Mailpit smoke output; and
4. the final smoke result.

Treat anonymous visibility and pull as a post-publication release gate. Do not
mark CLI-2138 complete until the later CLI repository wiring passes stack
lifecycle acceptance.
