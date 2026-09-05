# shellcheck shell=bash
# One pure flake invocation for release builds and packaging. Sourced by callers.

nix_release() {
  local operation="$1" release_dir="$2" installable="$3"
  shift 3
  release_dir="$(cd "$release_dir" && pwd -P)"
  local input_args=(--override-input release "path:$release_dir" --no-write-lock-file)
  if [[ -f "$release_dir/source/flake.nix" ]] && python3 -c 'import json,sys; raise SystemExit(0 if json.load(open(sys.argv[1]))["service"] in ("postgres", "edge-runtime") else 1)' "$release_dir/release.json"; then
    input_args+=(--override-input upstream "path:$release_dir/source")
  fi
  nix --extra-experimental-features 'nix-command flakes' --accept-flake-config "$operation" \
    "$ROOT_DIR#$installable" "${input_args[@]}" "$@"
}

nix_tool() {
  nix --extra-experimental-features 'nix-command flakes' --accept-flake-config build \
    "$ROOT_DIR#$1^out" --no-write-lock-file --no-link --print-out-paths
}

# Expected hash mismatches are used only during release input resolution.
# A failed compiler/fetch with no hash remains a failed release.
nix_probe_hash() {
  local release_dir="$1" system="$2" key="$3" probe_log probe_status resolved
  probe_log="$(mktemp "${TMPDIR:-/tmp}/slim-nix-probe.XXXXXX")"
  if nix_release build "$release_dir" "legacyPackages.$system.dependencyProbes.$key" --no-link >"$probe_log" 2>&1; then
    cat "$probe_log" >&2
    rm -f "$probe_log"
    printf 'dependency probe unexpectedly accepted the placeholder hash: %s\n' "$key" >&2
    return 1
  else
    probe_status=$?
  fi
  cat "$probe_log" >&2
  resolved="$(sed -nE 's/.*got:[[:space:]]+(sha256-[A-Za-z0-9+\/=]+).*/\1/p' "$probe_log" | tail -n 1)"
  rm -f "$probe_log"
  if [[ -z "$resolved" ]]; then
    printf 'Nix failed without resolving %s; see the build error above\n' "$key" >&2
    return "$probe_status"
  fi
  printf '%s\n' "$resolved"
}
