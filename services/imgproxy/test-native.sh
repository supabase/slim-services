#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${IMGPROXY_VERSION:-v3.8.0}"
temp_root="${TMPDIR:-/tmp}"
temp_root="${temp_root%/}"
result_dir=""
result_link=""
loader_proof=""
proof_root=""

cleanup_result_link() {
  case "$result_dir" in
    "$temp_root"/imgproxy-native-result.*)
      if [[ -n "$result_link" && "$result_link" == "$result_dir/result" && -d "$result_dir" && ! -L "$result_dir" ]]; then
        rm -rf "$result_dir"
      fi
      ;;
  esac
}

cleanup_proof_dir() {
  local proof_dir="$1"
  case "$proof_dir" in
    "$temp_root"/imgproxy-loader-proof.*|"$temp_root"/imgproxy-floor-proof.*)
      if [[ -d "$proof_dir" && ! -L "$proof_dir" ]]; then
        rm -rf "$proof_dir"
      fi
      ;;
  esac
}

cleanup_test_paths() {
  cleanup_result_link
  cleanup_proof_dir "$loader_proof"
  cleanup_proof_dir "$proof_root"
}
trap cleanup_test_paths EXIT

if [[ -n "${ARTIFACT_ROOTFS:-}" ]]; then
  rootfs="$ARTIFACT_ROOTFS"
else
  command -v nix-build >/dev/null 2>&1 || {
    printf 'nix-build is required when ARTIFACT_ROOTFS is unset\n' >&2
    exit 2
  }
  : "${IMGPROXY_SOURCE_REPOSITORY:?IMGPROXY_SOURCE_REPOSITORY is required for a source build}"
  : "${IMGPROXY_SOURCE_COMMIT:?IMGPROXY_SOURCE_COMMIT is required for a source build}"
  : "${IMGPROXY_SOURCE_HASH:?IMGPROXY_SOURCE_HASH is required for a source build}"
  : "${IMGPROXY_VENDOR_HASH:?IMGPROXY_VENDOR_HASH is required for a source build}"
  result_dir="$(mktemp -d "$temp_root/imgproxy-native-result.XXXXXX")"
  result_link="$result_dir/result"
  nix-build "$ROOT_DIR/services/imgproxy/nix" \
    -A imgproxy \
    --argstr serviceVersion "$VERSION" \
    --argstr sourceRepository "$IMGPROXY_SOURCE_REPOSITORY" \
    --argstr sourceCommit "$IMGPROXY_SOURCE_COMMIT" \
    --argstr sourceHash "$IMGPROXY_SOURCE_HASH" \
    --argstr vendorHash "$IMGPROXY_VENDOR_HASH" \
    --out-link "$result_link"
  rootfs="$result_link"
fi

[[ -x "$rootfs/bin/imgproxy" ]] || {
  printf 'imgproxy rootfs is missing executable: %s/bin/imgproxy\n' "$rootfs" >&2
  exit 1
}
rootfs="$(cd "$rootfs" && pwd -P)"

store_leaks="$(mktemp "${TMPDIR:-/tmp}/imgproxy-store-leaks.XXXXXX")"
while IFS= read -r artifact_file; do
  if file "$artifact_file" | grep -qE 'Mach-O|ELF'; then
    continue
  fi
  grep -aIl '/nix/store/' "$artifact_file" >>"$store_leaks" 2>/dev/null || true
done < <(find "$rootfs" -type f -print)
if [[ -s "$store_leaks" ]]; then
  cat "$store_leaks" >&2
  rm -f "$store_leaks"
  printf 'imgproxy rootfs contains /nix/store text references\n' >&2
  exit 1
fi
rm -f "$store_leaks"

if [[ "$(uname -s)" == Linux ]]; then
  loader_proof="$(mktemp -d "$temp_root/imgproxy-loader-proof.XXXXXX")"
  cp -R "$rootfs"/. "$loader_proof"/
  chmod -R u+w "$loader_proof"
  loader_path="$(find "$loader_proof/lib" -maxdepth 1 -type f -name 'ld-linux-*.so.*' -print -quit)"
  if [[ -z "$loader_path" ]]; then
    rm -rf "$loader_proof"
    printf 'imgproxy loader regression could not find bundled Linux loader\n' >&2
    exit 1
  fi
  rm -f "$loader_path"
  for wrapper in imgproxy vips; do
    check_output="$(mktemp "$temp_root/imgproxy-loader-check.XXXXXX")"
    if "$loader_proof/bin/$wrapper" --help >"$check_output" 2>&1; then
      status=0
    else
      status=$?
    fi
    if [[ "$status" -eq 0 ]] || ! grep -q 'bundled loader missing' "$check_output"; then
      cat "$check_output" >&2
      rm -f "$check_output"
      rm -rf "$loader_proof"
      printf 'imgproxy loader regression failed for %s\n' "$wrapper" >&2
      exit 1
    fi
    rm -f "$check_output"
  done
  rm -rf "$loader_proof"
  loader_proof=""
  printf 'imgproxy bundled-loader regression passed\n'
fi

ARTIFACT_ROOTFS="$rootfs" "$ROOT_DIR/services/imgproxy/smoke.sh"

if [[ "$(uname -s)" == Darwin ]] && command -v sandbox-exec >/dev/null 2>&1; then
  proof_root="$(mktemp -d "$temp_root/imgproxy-floor-proof.XXXXXX")"
  cp -R "$rootfs"/. "$proof_root"/
  chmod -R u+w "$proof_root"
  proof_profile="(version 1) (allow default) (deny file-read* (subpath \"/nix/store\"))"
  IMGPROXY_SKIP_RUNTIME_SAMPLE=1 ARTIFACT_ROOTFS="$proof_root" \
    sandbox-exec -p "$proof_profile" "$ROOT_DIR/services/imgproxy/smoke.sh"
  rm -rf "$proof_root"
  proof_root=""
fi

if [[ "$(uname -s)" == Darwin ]]; then
  "$ROOT_DIR/scripts/audit-portable-artifact.sh" --darwin "$rootfs"
elif [[ "$(uname -s)" == Linux ]]; then
  "$ROOT_DIR/scripts/audit-portable-artifact.sh" --linux "$rootfs"
fi

printf 'imgproxy native integration test passed (%s)\n' "$rootfs"
