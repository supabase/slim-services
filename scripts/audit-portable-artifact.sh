#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scripts/audit-portable-artifact.sh --darwin ROOTFS
  scripts/audit-portable-artifact.sh --linux ROOTFS

Fail if a portable artifact still has unresolved or host-specific runtime
deps, ships an ELF with a non-standard program interpreter, or exceeds the
OS floor policy (glibc 2.38 on Linux, macOS 13.0 on darwin; override with
GLIBC_FLOOR_MAX / MACOS_FLOOR_MAX or SLIM_GLIBC_FLOOR_MAX /
SLIM_MACOS_FLOOR_MAX).
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

mode="$1"
rootfs="$2"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"

# Symlinks must stay relative on every platform: an absolute target (a Nix
# store leak, or any host path) breaks the moment the artifact is extracted
# somewhere else. Relative links are also what the dedup pass in portable
# packaging emits, so this doubles as its regression check.
bad_symlinks="$(
  find "$rootfs" -type l 2>/dev/null \
    | while IFS= read -r link_path; do
        target="$(readlink "$link_path")"
        # No case statement here: the pattern-closing paren inside a command
        # substitution is a parse error on macOS bash 3.2.
        if [[ "$target" == /* ]]; then
          printf '%s -> %s\n' "$link_path" "$target"
        fi
      done
)"
if [[ -n "$bad_symlinks" ]]; then
  printf '%s\n' "$bad_symlinks" >&2
  fail "artifact contains absolute symlinks (not relocatable)"
fi

case "$mode" in
  --darwin)
    require_cmd file
    require_cmd otool
    require_cmd codesign
    require_cmd python3
    unresolved="$(
      find "$rootfs" -type f 2>/dev/null \
        | while IFS= read -r file_path; do
            if file "$file_path" | grep -q 'Mach-O'; then
              # An invalid signature means macOS SIGKILLs the process that
              # loads the file — an in-sandbox codesign shim can produce
              # these on special dylibs (reexport stubs).
              if ! codesign --verify "$file_path" >/dev/null 2>&1; then
                printf '%s -> invalid code signature\n' "$file_path"
              fi
              # /nix/store: build machine leak. /opt/homebrew + /usr/local:
              # package-manager paths not guaranteed on user machines.
              otool -L "$file_path" 2>/dev/null \
                | awk -v file="$file_path" 'NR > 1 && ($1 ~ "^/nix/store/" || $1 ~ "^/opt/homebrew/" || $1 ~ "^/usr/local/") { print file " -> " $1 }'
              otool -l "$file_path" 2>/dev/null \
                | awk -v file="$file_path" '
                    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
                    in_rpath && $1 == "path" && $2 ~ "^/nix/store/" { print file " rpath -> " $2; in_rpath = 0 }
                    in_rpath && $1 == "path" { in_rpath = 0 }
                  '
            fi
          done
    )"
    if [[ -n "$unresolved" ]]; then
      printf '%s\n' "$unresolved" >&2
      fail "Darwin artifact contains absolute Nix store references"
    fi
    # Host floor gate: highest Mach-O deployment target shipped must stay
    # within the supported macOS policy (CI_MATRIX.md).
    floor_json="$("$ROOT_DIR/scripts/os-floor.sh" --darwin "$rootfs")"
    log "darwin floor: $floor_json"
    macos_floor_max="${MACOS_FLOOR_MAX:-${SLIM_MACOS_FLOOR_MAX:-13.0}}"
    python3 - "$floor_json" "$macos_floor_max" <<'PY' || fail "Darwin artifact exceeds the macOS floor policy"
import json
import sys

info = json.loads(sys.argv[1])
limit = tuple(int(x) for x in sys.argv[2].split("."))
floor = info.get("floor")
if floor is None:
    raise SystemExit(0)
if tuple(int(x) for x in floor.split(".")) > limit:
    print(f"[slim] ERROR: macOS floor {floor} exceeds policy {sys.argv[2]}"
          f" (offender: {info.get('offender')})", file=sys.stderr)
    raise SystemExit(1)
PY
    ;;
  --linux)
    require_cmd file
    require_cmd ldd
    require_cmd readelf
    require_cmd python3
    # Resolve against the artifact's own library dirs first (including Debian
    # multiarch dirs) so bundled libs don't get checked against older host
    # copies of the same soname.
    lib_path="$rootfs/usr/local/lib:$rootfs/lib:$rootfs/usr/lib"
    for dir in "$rootfs"/lib/*-linux-gnu* "$rootfs"/usr/lib/*-linux-gnu*; do
      [[ -d "$dir" ]] && lib_path="$lib_path:$dir"
    done
    unresolved="$(
      find "$rootfs" -type f 2>/dev/null \
        | while IFS= read -r file_path; do
            if file "$file_path" | grep -q 'ELF'; then
              # ldd exits nonzero on statically linked binaries; that is a
              # pass, not an audit error, so keep pipefail from killing the
              # scan. (No apostrophes here: bash 3.2 on macOS mis-parses
              # quotes in comments inside command substitutions.)
              LD_LIBRARY_PATH="$lib_path:${LD_LIBRARY_PATH:-}" \
                ldd "$file_path" 2>/dev/null \
                | awk -v file="$file_path" '/not found/ { print file " -> " $0 }' \
                || true
              # Absolute store paths in NEEDED/RPATH RESOLVE on a build
              # machine (its /nix/store exists), so the ldd pass above cannot
              # catch them — reject the strings themselves. (Real leak seen:
              # nixpkgs proj/gdal carry an absolute NEEDED for libsqlite3.)
              readelf -d "$file_path" 2>/dev/null \
                | awk -v file="$file_path" '/NEEDED|RUNPATH|RPATH/ && /\/nix\/store\// { print file " -> " $0 }' \
                || true
            fi
          done
    )"
    if [[ -n "$unresolved" ]]; then
      printf '%s\n' "$unresolved" >&2
      fail "Linux artifact has unresolved shared-library dependencies"
    fi
    # Every ELF must request the standard system loader for the target arch.
    # Anything else — a /nix/store loader (build-machine leak, resolves only
    # where that store exists) or a musl loader on a glibc target — breaks
    # the moment the archive lands on a clean host. (Real leak class seen:
    # a bundled Nix store subtree whose ELFs kept their store interpreters.)
    case "$(uname -m)" in
      aarch64|arm64) allowed_interp="/lib/ld-linux-aarch64.so.1" ;;
      x86_64|amd64) allowed_interp="/lib64/ld-linux-x86-64.so.2" ;;
      *) fail "unsupported audit architecture: $(uname -m)" ;;
    esac
    bad_interps="$(
      find "$rootfs" -type f 2>/dev/null \
        | while IFS= read -r file_path; do
            if file "$file_path" | grep -q 'ELF'; then
              readelf -l "$file_path" 2>/dev/null \
                | awk -v file="$file_path" -v ok="$allowed_interp" '
                    /Requesting program interpreter/ {
                      line = $0
                      sub(/^.*\[/, "", line)
                      sub(/\].*$/, "", line)
                      if (line != ok) print file " -> " line
                    }'
            fi
          done
    )"
    if [[ -n "$bad_interps" ]]; then
      printf '%s\n' "$bad_interps" >&2
      fail "Linux artifact contains ELFs with non-standard program interpreters (expected $allowed_interp)"
    fi
    # Host floor gate: the highest GLIBC_x.y requirement any shipped ELF
    # places on the host must stay within the supported-host policy
    # (CI_MATRIX.md). Artifacts that bundle their own libc + loader pair are
    # a different (hermetic) contract and are proven by the floor-container
    # execution check instead.
    floor_json="$("$ROOT_DIR/scripts/os-floor.sh" --linux "$rootfs")"
    log "linux floor: $floor_json"
    glibc_floor_max="${GLIBC_FLOOR_MAX:-${SLIM_GLIBC_FLOOR_MAX:-2.38}}"
    python3 - "$floor_json" "$glibc_floor_max" <<'PY' || fail "Linux artifact exceeds the glibc floor policy"
import json
import sys

info = json.loads(sys.argv[1])
limit = tuple(int(x) for x in sys.argv[2].split("."))
if info.get("bundled_glibc"):
    print(f"[slim] glibc floor gate skipped: artifact bundles its own glibc"
          f" (measured floor {info.get('floor')})")
    raise SystemExit(0)
floor = info.get("floor")
if floor is None:
    raise SystemExit(0)
if tuple(int(x) for x in floor.split(".")) > limit:
    print(f"[slim] ERROR: glibc floor {floor} exceeds policy {sys.argv[2]}"
          f" (offender: {info.get('offender')})", file=sys.stderr)
    raise SystemExit(1)
PY
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

log "portable artifact audit passed: $mode $rootfs"
