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
deps, ships a non-glibc consumer ELF with a non-standard program interpreter, or exceeds the
OS floor policy (glibc 2.35 on Linux, macOS 14.0 on darwin; override with
GLIBC_FLOOR_MAX / MACOS_FLOOR_MAX or SLIM_GLIBC_FLOOR_MAX /
SLIM_MACOS_FLOOR_MAX).
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 2 ]] || { usage >&2; exit 2; }

mode="$1"
rootfs="$2"
[[ -d "$rootfs" ]] || fail "rootfs directory not found: $rootfs"
require_cmd python3

# Every emitted symlink must resolve with real filesystem semantics to an
# existing path inside the artifact root. This catches absolute build-host
# leaks as well as dangling or escaping relative pnpm links.
symlink_errors=""
if ! symlink_errors="$(python3 "$ROOT_DIR/scripts/validate-artifact-symlinks.py" "$rootfs" 2>&1)"; then
  printf '%s\n' "$symlink_errors" >&2
  fail "artifact contains invalid symlinks"
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
    floor_json="$("$ROOT_DIR/scripts/os-floor.sh" --darwin "$rootfs")" \
      || fail "os-floor scan failed for $rootfs"
    log "darwin floor: $floor_json"
    macos_floor_max="${MACOS_FLOOR_MAX:-${SLIM_MACOS_FLOOR_MAX:-14.0}}"
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
    require_cmd readelf
    require_cmd python3
    case "$(uname -m)" in
      aarch64|arm64)
        allowed_interp="/lib/ld-linux-aarch64.so.1"
        loader_name="ld-linux-aarch64.so.1"
        multiarch_triplet="aarch64-linux-gnu"
        ;;
      x86_64|amd64)
        allowed_interp="/lib64/ld-linux-x86-64.so.2"
        loader_name="ld-linux-x86-64.so.2"
        multiarch_triplet="x86_64-linux-gnu"
        ;;
      *) fail "unsupported audit architecture: $(uname -m)" ;;
    esac
    # Resolve against the artifact's own library dirs first (including Debian
    # multiarch dirs) so bundled libs don't get checked against older host
    # copies of the same soname.
    lib_path="$rootfs/usr/local/lib:$rootfs/lib:$rootfs/usr/lib"
    for dir in "$rootfs"/lib/*-linux-gnu* "$rootfs"/usr/lib/*-linux-gnu*; do
      [[ -d "$dir" ]] && lib_path="$lib_path:$dir"
    done
    # Service-native addons may be staged in these artifact-owned closure
    # directories. Include only directories that exist; never add host paths.
    for dir in "$rootfs/dylib" "$rootfs/node/dylib"; do
      [[ -d "$dir" ]] && lib_path="$lib_path:$dir"
    done
    canonical_loaders=()
    canonical_loader_ids=()
    for candidate in "$rootfs$allowed_interp" "$rootfs/lib/$loader_name"; do
      [[ -x "$candidate" ]] || continue
      candidate_id="$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")"
      duplicate=false
      if ((${#canonical_loader_ids[@]} > 0)); then
        for selected_id in "${canonical_loader_ids[@]}"; do
          [[ "$selected_id" == "$candidate_id" ]] && duplicate=true
        done
      fi
      if [[ "$duplicate" != "true" ]]; then
        canonical_loaders+=("$candidate")
        canonical_loader_ids+=("$candidate_id")
      fi
    done
    multiarch_loaders=()
    multiarch_loader_ids=()
    mismatched_multiarch_loaders=()
    for candidate in "$rootfs"/lib/*-linux-gnu*/ld-linux-*; do
      [[ -x "$candidate" ]] || continue
      candidate_triplet="$(basename "$(dirname "$candidate")")"
      candidate_name="$(basename "$candidate")"
      if [[ "$candidate_triplet" != "$multiarch_triplet" || "$candidate_name" != "$loader_name" ]]; then
        mismatched_multiarch_loaders+=("$candidate")
        continue
      fi
      candidate_id="$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")"
      duplicate=false
      if ((${#canonical_loader_ids[@]} > 0)); then
        for selected_id in "${canonical_loader_ids[@]}"; do
          [[ "$selected_id" == "$candidate_id" ]] && duplicate=true
        done
      fi
      [[ "$duplicate" == "true" ]] && continue
      duplicate=false
      if ((${#multiarch_loader_ids[@]} > 0)); then
        for selected_id in "${multiarch_loader_ids[@]}"; do
          [[ "$selected_id" == "$candidate_id" ]] && duplicate=true
        done
      fi
      if [[ "$duplicate" != "true" ]]; then
        multiarch_loaders+=("$candidate")
        multiarch_loader_ids+=("$candidate_id")
      fi
    done
    if ((${#mismatched_multiarch_loaders[@]} > 0)); then
      fail "Linux artifact has mismatched multiarch bundled loaders: ${mismatched_multiarch_loaders[*]}"
    fi
    if ((${#canonical_loaders[@]} > 1)); then
      fail "Linux artifact has ambiguous canonical bundled loaders: ${canonical_loaders[*]}"
    fi
    if ((${#multiarch_loaders[@]} > 1)); then
      fail "Linux artifact has ambiguous multiarch bundled loaders: ${multiarch_loaders[*]}"
    fi
    if ((${#canonical_loaders[@]} == 1 && ${#multiarch_loaders[@]} == 1)); then
      fail "Linux artifact has ambiguous canonical and multiarch bundled loaders"
    fi
    bundled_loader=""
    bundled_lib_path=""
    if ((${#canonical_loaders[@]} == 1)); then
      bundled_loader="${canonical_loaders[0]}"
      canonical_libc_paths=()
      canonical_libc_ids=()
      for lib_dir in \
        "$rootfs/lib" \
        "$rootfs/lib64" \
        "$rootfs/usr/lib" \
        "$rootfs/lib/$multiarch_triplet" \
        "$rootfs/usr/lib/$multiarch_triplet"
      do
        candidate="$lib_dir/libc.so.6"
        [[ -e "$candidate" ]] || continue
        candidate_id="$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        duplicate=false
        if ((${#canonical_libc_ids[@]} > 0)); then
          for selected_id in "${canonical_libc_ids[@]}"; do
            [[ "$selected_id" == "$candidate_id" ]] && duplicate=true
          done
        fi
        if [[ "$duplicate" != "true" ]]; then
          canonical_libc_paths+=("$candidate")
          canonical_libc_ids+=("$candidate_id")
        fi
      done
      ((${#canonical_libc_paths[@]} == 1)) || {
        if ((${#canonical_libc_paths[@]} == 0)); then
          fail "Linux artifact canonical bundled loader has no paired libc"
        fi
        fail "Linux artifact has ambiguous canonical bundled libcs: ${canonical_libc_paths[*]}"
      }
      bundled_lib_path="$(dirname "${canonical_libc_paths[0]}")"
      lib_path="$bundled_lib_path:$lib_path"
    elif ((${#multiarch_loaders[@]} == 1)); then
      bundled_loader="${multiarch_loaders[0]}"
      bundled_lib_path="$rootfs/lib/$multiarch_triplet"
      [[ -e "$bundled_lib_path/libc.so.6" ]] || {
        fail "Linux artifact multiarch bundled loader has no paired libc: $bundled_lib_path/libc.so.6"
      }
      lib_path="$bundled_lib_path:$lib_path"
    fi
    [[ -n "$bundled_loader" ]] || require_cmd ldd
    unresolved="$(
      find "$rootfs" -type f 2>/dev/null \
        | while IFS= read -r file_path; do
            # Ask file(1) for description-only output; never let words in an
            # ELF filename influence static/dynamic classification.
            file_description="$(file -b -- "$file_path" 2>/dev/null || true)"
            if [[ "$file_description" == *ELF* ]]; then
              if [[ "$file_path" == "$bundled_loader" ]]; then
                continue
              elif [[ -n "$bundled_loader" ]]; then
                # Host ldd can crash or resolve against the wrong libc when an
                # artifact bundles glibc. Ask the artifact loader directly so
                # this is also a hermetic dependency-resolution proof.
                loader_output=""
                if loader_output="$("$bundled_loader" --library-path "$lib_path" --list "$file_path" 2>&1)"; then
                  awk -v file="$file_path" '/not found/ { print file " -> " $0 }' <<< "$loader_output"
                else
                  printf '%s -> bundled loader audit failed: %s\n' "$file_path" "$loader_output"
                fi
              else
                ldd_output=""
                ldd_status=0
                if ldd_output="$(
                  LD_LIBRARY_PATH="$lib_path:${LD_LIBRARY_PATH:-}" \
                    ldd "$file_path" 2>&1
                )"; then
                  ldd_status=0
                else
                  ldd_status=$?
                fi
                if [[ "$ldd_status" -ne 0 ]]; then
                  if [[ "$file_description" != *"statically linked"* && "$file_description" != *"static-pie"* ]]; then
                    printf '%s -> ldd audit failed (status %s): %s\n' \
                      "$file_path" "$ldd_status" "$ldd_output"
                  fi
                fi
                awk -v file="$file_path" '/not found/ { print file " -> " $0 }' <<< "$ldd_output"
              fi
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
    # Every non-glibc consumer ELF must request the standard system loader for
    # the target arch. Bundled glibc implementation objects retain their own
    # interpreter metadata and are entered through the validated paired
    # loader above. Anything else — a /nix/store loader (build-machine leak,
    # resolves only where that store exists) or a musl loader on a glibc target
    # — breaks the moment the archive lands on a clean host. (Real leak class
    # seen: a bundled Nix store subtree whose consumer ELFs kept their store
    # interpreters.)
    is_bundled_glibc_object() {
      local file_path="$1"
      local file_name="${file_path##*/}"
      [[ -n "$bundled_lib_path" && "$file_path" == "$bundled_lib_path/"* ]] || return 1
      case "$file_name" in
        ld-linux*.so*|libc.so.6|libc-*.so.*|libm.so.6|libm-*.so.*|libmvec.so.1|libmvec-*.so.*|libpthread.so.0|libpthread-*.so.*|libdl.so.2|libdl-*.so.*|libresolv.so.2|libresolv-*.so.*|librt.so.1|librt-*.so.*|libutil.so.1|libutil-*.so.*|libanl.so.1|libanl-*.so.*|libBrokenLocale.so.1|libBrokenLocale-*.so.*|libthread_db.so.1|libthread_db-*.so.*|libnss_*.so.*|libnsl.so.1|libnsl-*.so.*)
          return 0
          ;;
        *)
          return 1
          ;;
      esac
    }
    bad_interps="$(
      find "$rootfs" -type f 2>/dev/null \
        | while IFS= read -r file_path; do
            if file "$file_path" | grep -q 'ELF'; then
              if is_bundled_glibc_object "$file_path"; then
                continue
              fi
              readelf -l "$file_path" 2>/dev/null \
                | awk -v file="$file_path" -v ok="$allowed_interp" '
                    /Requesting program interpreter/ {
                      line = $0
                      sub(/^.*interpreter: /, "", line)
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
    floor_json="$("$ROOT_DIR/scripts/os-floor.sh" --linux "$rootfs")" \
      || fail "os-floor scan failed for $rootfs"
    log "linux floor: $floor_json"
    glibc_floor_max="${GLIBC_FLOOR_MAX:-${SLIM_GLIBC_FLOOR_MAX:-2.35}}"
    python3 - "$floor_json" "$glibc_floor_max" "$([[ -n "$bundled_loader" ]] && printf true || printf false)" <<'PY' || fail "Linux artifact exceeds the glibc floor policy"
import json
import sys

info = json.loads(sys.argv[1])
limit = tuple(int(x) for x in sys.argv[2].split("."))
bundled_loader_present = sys.argv[3] == "true"
if info.get("bundled_glibc"):
    if not bundled_loader_present:
        print("[slim] ERROR: artifact reports bundled glibc but no executable bundled loader", file=sys.stderr)
        raise SystemExit(1)
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
