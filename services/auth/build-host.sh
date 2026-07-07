#!/usr/bin/env bash
set -euo pipefail
# Host-toolchain build for non-linux targets (invoked by
# scripts/build-artifact-from-source.sh with SERVICE/VERSION/TARGET_OS/ARCH/
# SOURCE_DIR/ROOTFS/ROOT_DIR set). Go cross-compiles darwin from any host;
# go.mod's toolchain directive pins the effective compiler version.

command -v go >/dev/null 2>&1 || {
  printf '[slim] ERROR: go toolchain required for auth host builds\n' >&2
  exit 1
}

mkdir -p "$ROOTFS/bin"

# Same flags as services/auth/Dockerfile.artifact. CGO_ENABLED=0 keeps the
# binary self-contained; migrations are embedded via go:embed in main.go, and
# TLS uses the platform trust store (no CA bundle needed on macOS).
(
  cd "$SOURCE_DIR"
  CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$ARCH" GOFLAGS=-mod=readonly \
    go build \
    -trimpath \
    -buildvcs=false \
    -ldflags "-s -w -X github.com/supabase/auth/internal/utilities.Version=${VERSION}" \
    -o "$ROOTFS/bin/auth" \
    .
)

ln -s auth "$ROOTFS/bin/gotrue"
chmod 0755 "$ROOTFS/bin/auth"
