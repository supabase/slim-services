#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/build-artifact-from-nix.sh SERVICE [VERSION]

Build SERVICE from a configured Nix flake/package and export runtime files
into the common artifact layout.

Source-backed recipes may declare NIX_SOURCE_ARGS_JSON, a JSON object mapping
Nix argument names to snapshot selectors (version, repository, or source.*).
When UPSTREAM_ASSETS_FILE is also set, the verified snapshot supplies the
source metadata and those arguments are passed to Nix in declaration order.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }

require_cmd git
require_cmd tar
require_cmd python3
PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

service="$1"
VERSION="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
if [[ -n "${PLATFORM:-}" ]]; then
  PLATFORM="$PLATFORM"
elif [[ "$TARGET_OS" == "linux" ]]; then
  PLATFORM="$(docker_platform "$TARGET_OS" "$ARCH")"
else
  PLATFORM="$TARGET_OS/$ARCH"
fi
DEFAULT_NIX_SYSTEM="$(nix_system_for "$TARGET_OS" "$ARCH")"

load_recipe "$service"

SOURCE_DIR="${SOURCE_DIR:-}"
SOURCE_REF="${SOURCE_REF:-}"
BASE_IMAGE="${BASE_IMAGE:?recipe must define BASE_IMAGE}"
ENTRYPOINT_JSON="${ENTRYPOINT_JSON:?recipe must define ENTRYPOINT_JSON}"
CMD_JSON="${CMD_JSON:-[]}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-${SOURCE_IMAGE:-}}"
NIX_FLAKE="${NIX_FLAKE:?recipe must define NIX_FLAKE}"
NIX_ATTR="${NIX_ATTR:?recipe must define NIX_ATTR}"
if [[ -n "${NIX_SYSTEM:-}" && "$NIX_SYSTEM" != "$DEFAULT_NIX_SYSTEM" ]]; then
  fail "NIX_SYSTEM=$NIX_SYSTEM does not match target $TARGET_OS/$ARCH ($DEFAULT_NIX_SYSTEM)"
fi
NIX_SYSTEM="$DEFAULT_NIX_SYSTEM"
NIX_RUNNER="${NIX_RUNNER:-auto}"
NIX_BUILD_MODE="${NIX_BUILD_MODE:-flake}"
NIX_BUILD_COMMAND_TEMPLATE="${NIX_BUILD_COMMAND_TEMPLATE:-}"
NIX_PACKAGE_OVERLAY="${NIX_PACKAGE_OVERLAY:-}"
NIX_PACKAGE_OVERLAY_DEST="${NIX_PACKAGE_OVERLAY_DEST:-}"
# Optional additional source trees copied into the temporary local build
# export. Each array item is `source:destination` (or source-only, which uses
# nix/<basename>), allowing shared package assets without service hardcoding.
nix_auxiliary_overlays=()
if declare -p NIX_AUXILIARY_OVERLAYS >/dev/null 2>&1; then
  nix_auxiliary_overlays=("${NIX_AUXILIARY_OVERLAYS[@]}")
fi
NIX_DERIVE_MIX_DEPS_HASH="${NIX_DERIVE_MIX_DEPS_HASH:-false}"

external_source=0
source_metadata_json=""
source_repository=""
nix_source_args_json="{}"
nix_source_args_file=""
nix_source_arg_values=()
if [[ -n "${NIX_SOURCE_ARGS_JSON:-}" ]]; then
  [[ -n "${UPSTREAM_ASSETS_FILE:-}" ]] || fail "NIX_SOURCE_ARGS_JSON requires UPSTREAM_ASSETS_FILE"
  source_policy_file="$UPSTREAM_ASSETS_FILE"
  [[ "$source_policy_file" = /* ]] || source_policy_file="$ROOT_DIR/$source_policy_file"
  [[ -f "$source_policy_file" ]] || fail "upstream source snapshot not found: $source_policy_file"

  source_metadata_json="$(python3 "$ROOT_DIR/scripts/upstream-release.py" source "$source_policy_file" "$VERSION")" \
    || fail "Nix backend requires a source record for $service $VERSION"
  source_repository="$(ROOT_DIR_ENV="$ROOT_DIR" python3 - "$source_policy_file" <<'PY'
import importlib.util
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
resolver = pathlib.Path(os.environ["ROOT_DIR_ENV"]) / "scripts" / "upstream-release.py"
spec = importlib.util.spec_from_file_location("upstream_release", resolver)
if spec is None or spec.loader is None:
    raise SystemExit("could not load snapshot validator")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.load_policy(path)["repository"])
PY
  )" || fail "could not validate upstream source snapshot: $source_policy_file"

  nix_source_args_file="$(mktemp "${TMPDIR:-/tmp}/slim-nix-source-args.XXXXXX")"
  cleanup_nix_source_args() { rm -f "$nix_source_args_file" "$nix_source_args_file.json"; }
  trap cleanup_nix_source_args EXIT
  if ! SOURCE_METADATA_JSON="$source_metadata_json" \
    NIX_SOURCE_ARGS_JSON="$NIX_SOURCE_ARGS_JSON" \
    SOURCE_REPOSITORY="$source_repository" \
    WORKFLOW_VERSION="$VERSION" \
    python3 - "$nix_source_args_file" <<'PY'
import json
import os
import re
import sys

output = sys.argv[1]

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate Nix argument name: {key!r}")
        result[key] = value
    return result

try:
    mapping = json.loads(
        os.environ["NIX_SOURCE_ARGS_JSON"], object_pairs_hook=reject_duplicate_keys
    )
except (KeyError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"NIX_SOURCE_ARGS_JSON must be valid JSON: {error}")
if not isinstance(mapping, dict) or not mapping:
    raise SystemExit("NIX_SOURCE_ARGS_JSON must be a non-empty JSON object")

argument_pattern = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
source = json.loads(os.environ["SOURCE_METADATA_JSON"])
repository = os.environ["SOURCE_REPOSITORY"]
version = os.environ["WORKFLOW_VERSION"]
resolved = {}
with open(output, "w", encoding="utf-8") as stream:
    for name, selector in mapping.items():
        if not isinstance(name, str) or argument_pattern.fullmatch(name) is None:
            raise SystemExit(f"unsafe Nix argument name: {name!r}")
        if not isinstance(selector, str):
            raise SystemExit(f"unsafe source selector for {name}: {selector!r}")
        if selector == "version":
            value = version
        elif selector == "repository":
            value = repository
        elif selector.startswith("source.") and selector[7:] in source:
            value = source[selector[7:]]
        else:
            raise SystemExit(f"unknown source selector for {name}: {selector!r}")
        if not isinstance(value, str) or not value or any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
            raise SystemExit(f"unsafe source value for {name}: {value!r}")
        resolved[name] = selector
        stream.write(f"{name}\t{value}\n")
with open(output + ".json", "w", encoding="utf-8") as stream:
    json.dump(resolved, stream, separators=(",", ":"))
PY
  then
    fail "could not resolve Nix source argument mapping"
  fi
  nix_source_args_json="$(cat "$nix_source_args_file.json")"
  while IFS=$'\t' read -r arg_name arg_value; do
    [[ -n "$arg_name" ]] || continue
    nix_source_arg_values+=(--argstr "$arg_name" "$arg_value")
  done < "$nix_source_args_file"
  external_source=1
  log "using verified upstream source snapshot for $service $VERSION"
fi

if [[ "$external_source" == "0" ]]; then
  [[ -n "$SOURCE_DIR" ]] || fail "recipe must define SOURCE_DIR"
  [[ -n "$SOURCE_REF" ]] || fail "recipe must define SOURCE_REF"
fi

derived_hash_specs=()
if declare -p NIX_DERIVED_HASH_SPECS >/dev/null 2>&1; then
  derived_hash_specs=("${NIX_DERIVED_HASH_SPECS[@]}")
elif [[ "$NIX_DERIVE_MIX_DEPS_HASH" == "true" ]]; then
  # Backward compatibility for recipes that still use the original boolean.
  derived_hash_specs=("mix-deps:mix_deps_hash")
fi

source_abs="$ROOT_DIR/${SOURCE_DIR:-}"
artifact_dir="$ROOT_DIR/artifacts/$service/$VERSION/$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"
sbom="$artifact_dir/$service-$VERSION-$(artifact_platform_dir "$TARGET_OS" "$ARCH").sbom.spdx.json"
out_link="$artifact_dir/nix-result"
derived_hashes_file="$artifact_dir/nix-derived-hashes.json"
derived_hashes_json="{}"

actual_ref=""
if [[ "$external_source" == "0" ]]; then
  [[ -d "$source_abs" ]] || fail "source submodule directory not found: $SOURCE_DIR"
  [[ -f "$source_abs/.git" || -d "$source_abs/.git" ]] || fail "source directory is not a git checkout: $SOURCE_DIR"

  expected_ref="$(resolve_source_ref "$source_abs" "$SOURCE_REF")"
  actual_ref="$(git -C "$source_abs" rev-parse HEAD)"
  if [[ "$actual_ref" != "$expected_ref" ]]; then
    fail "$SOURCE_DIR is at $actual_ref, expected $SOURCE_REF ($expected_ref). Run: git submodule update --init --recursive"
  fi

  if [[ -n "$(git -C "$source_abs" status --short)" ]]; then
    fail "$SOURCE_DIR has local modifications; Nix artifact builds require clean submodules"
  fi
else
  actual_ref="$(SOURCE_METADATA_JSON="$source_metadata_json" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["SOURCE_METADATA_JSON"])["commit"])
PY
  )"
fi

host_nix_system=""
if command -v nix >/dev/null 2>&1; then
  host_nix_system="$(nix eval --raw --impure --expr builtins.currentSystem 2>/dev/null || true)"
fi

if [[ "$NIX_RUNNER" == "auto" ]]; then
  if [[ "$TARGET_OS" != "linux" ]]; then
    resolved_nix_runner="local"
  elif [[ -n "$host_nix_system" && "$host_nix_system" == "$NIX_SYSTEM" ]]; then
    resolved_nix_runner="local"
  else
    resolved_nix_runner="docker"
  fi
else
  resolved_nix_runner="$NIX_RUNNER"
fi

if [[ "$resolved_nix_runner" == "local" && -n "$host_nix_system" && "$host_nix_system" != "$NIX_SYSTEM" ]]; then
  fail "local Nix runner is $host_nix_system, but target is $NIX_SYSTEM. Use a native runner for $TARGET_OS/$ARCH."
fi

if [[ "$external_source" == "1" ]]; then
  [[ "$resolved_nix_runner" == "local" ]] || {
    fail "external source builds require NIX_RUNNER=local"
  }
  [[ "$NIX_BUILD_MODE" == "nix-build" ]] || {
    fail "external source builds require NIX_BUILD_MODE=nix-build"
  }
  [[ -z "$NIX_BUILD_COMMAND_TEMPLATE" ]] || {
    fail "external source builds do not support NIX_BUILD_COMMAND_TEMPLATE"
  }
fi

rm -rf "$rootfs"
mkdir -p "$rootfs" "$artifact_dir"
rm -f "$out_link"
rm -f "$derived_hashes_file"

if ! declare -p NIX_COPY_PATHS >/dev/null 2>&1 && [[ "${NIX_OUTPUT_KIND:-copy-paths}" != "rootfs" ]]; then
  fail "recipe must define NIX_COPY_PATHS for Nix backend"
fi

nix_flake_for_build="$NIX_FLAKE"
build_dir=""
apply_nix_overlay() {
  local source_path="$1" destination_path="$2"
  local overlay_abs="$ROOT_DIR/$source_path"
  [[ -n "$source_path" && -n "$destination_path" ]] || fail "Nix auxiliary overlay requires source and destination"
  [[ "$source_path" != /* && "$destination_path" != /* ]] || fail "Nix auxiliary overlay paths must be relative"
  [[ "$source_path" != *".."* && "$destination_path" != *".."* ]] || fail "Nix auxiliary overlay paths may not contain .."
  [[ -e "$overlay_abs" ]] || fail "Nix auxiliary overlay not found: $source_path"
  log "applying Nix auxiliary overlay $source_path -> $destination_path"
  if [[ -d "$overlay_abs" ]]; then
    mkdir -p "$build_src/$destination_path"
    cp -R "$overlay_abs/." "$build_src/$destination_path/"
  else
    mkdir -p "$(dirname "$build_src/$destination_path")"
    cp "$overlay_abs" "$build_src/$destination_path"
  fi
}

needs_local_overlay=false
if [[ -n "$NIX_PACKAGE_OVERLAY" || ${#nix_auxiliary_overlays[@]} -gt 0 ]]; then
  needs_local_overlay=true
fi
if [[ "$resolved_nix_runner" == "local" && "$needs_local_overlay" == "true" && "$external_source" == "0" ]]; then
  build_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-images-$service-$TARGET_OS-$ARCH.XXXXXX")"
  build_dir="$(cd "$build_dir" && pwd -P)"
  build_src="$build_dir/src"
  mkdir -p "$build_src"

  log "exporting $SOURCE_DIR@$actual_ref to temporary Nix build tree"
  git -C "$source_abs" archive HEAD | tar -C "$build_src" -xf -

  if [[ -n "$NIX_PACKAGE_OVERLAY" ]]; then
    overlay_abs="$ROOT_DIR/$NIX_PACKAGE_OVERLAY"
    [[ -e "$overlay_abs" ]] || fail "Nix package overlay not found: $NIX_PACKAGE_OVERLAY"
    NIX_PACKAGE_OVERLAY_DEST="${NIX_PACKAGE_OVERLAY_DEST:-nix/$(basename "$NIX_PACKAGE_OVERLAY")}"

    log "applying Nix package overlay $NIX_PACKAGE_OVERLAY -> $NIX_PACKAGE_OVERLAY_DEST"
    if [[ -d "$overlay_abs" ]]; then
      mkdir -p "$build_src/$NIX_PACKAGE_OVERLAY_DEST"
      cp -R "$overlay_abs/." "$build_src/$NIX_PACKAGE_OVERLAY_DEST/"
    else
      mkdir -p "$(dirname "$build_src/$NIX_PACKAGE_OVERLAY_DEST")"
      cp "$overlay_abs" "$build_src/$NIX_PACKAGE_OVERLAY_DEST"
    fi
  fi
  # Bash 3 (the system shell on macOS runners) raises an unbound-variable
  # error when expanding an empty array under `set -u`. Guard the expansion
  # so recipes with only a package overlay can still use the local export path.
  if ((${#nix_auxiliary_overlays[@]} > 0)); then
    for auxiliary_overlay in "${nix_auxiliary_overlays[@]}"; do
      if [[ "$auxiliary_overlay" == *:* ]]; then
        apply_nix_overlay "${auxiliary_overlay%%:*}" "${auxiliary_overlay#*:}"
      else
        apply_nix_overlay "$auxiliary_overlay" "nix/$(basename "$auxiliary_overlay")"
      fi
    done
  fi
  nix_flake_for_build="$build_src"
fi

case "$NIX_BUILD_MODE" in
  flake)
    if [[ "$NIX_ATTR" == packages.* || "$NIX_ATTR" == legacyPackages.* ]]; then
      nix_installable="${nix_flake_for_build}#${NIX_ATTR}"
    else
      nix_installable="${nix_flake_for_build}#packages.${NIX_SYSTEM}.${NIX_ATTR}"
    fi
    ;;
  nix-build)
    # NIX_EXPRESSION points at the .nix file or directory (relative to the
    # build tree) holding the attribute set, e.g. "nix" for repo-owned
    # services/<service>/nix/default.nix overlays.
    nix_installable="${nix_flake_for_build}/${NIX_EXPRESSION:-.} -A ${NIX_ATTR}"
    ;;
  *)
    fail "unknown NIX_BUILD_MODE for $service: $NIX_BUILD_MODE"
    ;;
esac

case "$resolved_nix_runner" in
  local)
    require_cmd nix
    log "building $service artifact with local Nix from $nix_installable"
    case "$NIX_BUILD_MODE" in
      flake)
        (
          cd "$ROOT_DIR"
          if [[ ${#derived_hash_specs[@]} -gt 0 ]]; then
            [[ "$external_source" == "0" ]] || fail "external Nix source builds cannot use derived hash discovery"
            "$ROOT_DIR/scripts/nix-build-with-derived-hashes.sh" \
              flake "$nix_installable" - "$VERSION" \
              "$out_link" "$derived_hashes_file" \
              "${derived_hash_specs[@]}"
          elif [[ -n "$NIX_BUILD_COMMAND_TEMPLATE" ]]; then
            export NIX_INSTALLABLE="$nix_installable"
            export NIX_SYSTEM="$NIX_SYSTEM"
            export NIX_OUT_LINK="$out_link"
            log "using explicit Nix build command template"
            bash -lc "$NIX_BUILD_COMMAND_TEMPLATE"
          else
            if [[ ${#nix_source_arg_values[@]} -gt 0 ]]; then
              nix --extra-experimental-features "nix-command flakes" build \
                "${nix_source_arg_values[@]}" "$nix_installable" \
                --out-link "$out_link"
            else
              nix --extra-experimental-features "nix-command flakes" build \
                "$nix_installable" --out-link "$out_link"
            fi
          fi
        )
        ;;
      nix-build)
        (
          cd "$ROOT_DIR"
          if [[ ${#derived_hash_specs[@]} -gt 0 ]]; then
            [[ "$external_source" == "0" ]] || fail "external Nix source builds cannot use derived hash discovery"
            "$ROOT_DIR/scripts/nix-build-with-derived-hashes.sh" \
              nix-build "$nix_flake_for_build/${NIX_EXPRESSION:-.}" \
              "$NIX_ATTR" "$VERSION" "$out_link" "$derived_hashes_file" \
              "${derived_hash_specs[@]}"
          else
            if [[ ${#nix_source_arg_values[@]} -gt 0 ]]; then
              nix-build "$nix_flake_for_build/${NIX_EXPRESSION:-.}" \
                -A "$NIX_ATTR" "${nix_source_arg_values[@]}" --out-link "$out_link"
            else
              nix-build "$nix_flake_for_build/${NIX_EXPRESSION:-.}" \
                -A "$NIX_ATTR" --out-link "$out_link"
            fi
          fi
        )
        ;;
    esac

    if [[ "${NIX_OUTPUT_KIND:-copy-paths}" == "rootfs" ]]; then
      log "copying full Nix rootfs output from $out_link"
      tar -C "$out_link" -cf - . | tar -C "$rootfs" -xf -
    else
      copy_nix_path() {
        local spec="$1"
        local src_path dst_path src dst
        if [[ "$spec" == *:* ]]; then
          src_path="${spec%%:*}"
          dst_path="${spec#*:}"
        else
          src_path="$spec"
          dst_path="$spec"
        fi
        src="$out_link${src_path}"
        dst="$rootfs${dst_path}"
        [[ -e "$src" ]] || fail "Nix output path not found: $src_path in $out_link"
        mkdir -p "$(dirname "$dst")"
        cp -RL "$src" "$dst"
      }

      for path in "${NIX_COPY_PATHS[@]}"; do
        copy_nix_path "$path"
      done
    fi

    chmod -R u+w "$rootfs"

    if [[ -f "$(service_dir "$service")/wrapper.sh" ]]; then
      wrapper_path="${WRAPPER_PATH:-/usr/local/bin/$service}"
      mkdir -p "$rootfs$(dirname "$wrapper_path")"
      cp "$(service_dir "$service")/wrapper.sh" "$rootfs$wrapper_path"
      chmod 0755 "$rootfs$wrapper_path"
    fi
    ;;
  docker)
    [[ "$TARGET_OS" == "linux" ]] || fail "Docker-hosted Nix builds are only supported for linux targets"
    require_cmd docker
    dockerfile="$ROOT_DIR/services/$service/Dockerfile.artifact"
    [[ -f "$dockerfile" ]] || fail "Nix Docker runner requires $dockerfile"
    docker_builder="${DOCKER_BUILDER:-$(docker context show 2>/dev/null || echo default)}"
    log "building $service artifact with Docker-hosted Nix from $SOURCE_DIR for $PLATFORM using builder $docker_builder"
    docker buildx build \
      --builder "$docker_builder" \
      --platform "$PLATFORM" \
      --target artifact \
      --output "type=local,dest=$rootfs" \
      -f "$dockerfile" \
      --build-arg "SOURCE_DIR=$SOURCE_DIR" \
      --build-arg "SERVICE_VERSION=$VERSION" \
      --build-arg "NIX_ATTR=$NIX_ATTR" \
      --build-arg "NIX_SYSTEM=$NIX_SYSTEM" \
      --build-arg "NIX_EXPRESSION=${NIX_EXPRESSION:-default.nix}" \
      "$ROOT_DIR"

    if [[ -f "$rootfs/.slim-nix-derived-hashes.json" ]]; then
      mv "$rootfs/.slim-nix-derived-hashes.json" "$derived_hashes_file"
    fi

    chmod -R u+w "$rootfs"

    if [[ -f "$(service_dir "$service")/wrapper.sh" ]]; then
      wrapper_path="${WRAPPER_PATH:-/usr/local/bin/$service}"
      mkdir -p "$rootfs$(dirname "$wrapper_path")"
      cp "$(service_dir "$service")/wrapper.sh" "$rootfs$wrapper_path"
      chmod 0755 "$rootfs$wrapper_path"
    fi
    ;;
  *)
    fail "unknown NIX_RUNNER for $service: $resolved_nix_runner"
    ;;
esac

if [[ ${#derived_hash_specs[@]} -gt 0 ]]; then
  [[ -s "$derived_hashes_file" ]] || fail "Nix derived hashes were not recorded"
  python3 -m json.tool "$derived_hashes_file" >/dev/null \
    || fail "Nix derived hash metadata is not valid JSON"
  derived_hashes_json="$(tr -d '\n' < "$derived_hashes_file")"
  rm -f "$derived_hashes_file"
fi

# The Nix sandbox signs with the sigtool shim, which produces invalid
# signatures on some special Mach-O layouts (e.g. reexport stubs like
# libiconv.dylib) — macOS SIGKILLs anything that loads such a file. Repair
# with the host's real codesign; the darwin audit fails the build if any
# invalid signature survives.
if [[ "$TARGET_OS" == "darwin" ]]; then
  log "verifying/repairing Mach-O code signatures with host codesign"
  find "$rootfs" -type f | while IFS= read -r macho; do
    file "$macho" 2>/dev/null | grep -q 'Mach-O' || continue
    if ! /usr/bin/codesign --verify "$macho" >/dev/null 2>&1; then
      chmod u+w "$macho" 2>/dev/null || true
      /usr/bin/codesign --force --sign - "$macho" 2>/dev/null \
        && log "re-signed: ${macho#"$rootfs"/}"
    fi
  done
fi

"$ROOT_DIR/scripts/prune-runtime-tree.sh" "$rootfs"
"$ROOT_DIR/scripts/generate-artifact-sbom.sh" \
  "$rootfs" "$sbom" "$service" "$VERSION" \
  "$(artifact_platform_dir "$TARGET_OS" "$ARCH")"
archive=""
if [[ "${ARTIFACT_ARCHIVE_ON_BUILD:-1}" == "1" ]]; then
  archive="$(archive_with_best_available_compressor "$rootfs" "$artifact_dir/$service")"
else
  rm -f "$artifact_dir/$service.tar" "$artifact_dir/$service.tar.gz" "$artifact_dir/$service.tar.zst"
fi

rootfs_kib="$(du -sk "$rootfs" | awk '{print $1}')"
archive_bytes=""
if [[ -n "$archive" ]]; then
  archive_bytes="$(wc -c < "$archive" | tr -d ' ')"
fi

portable="$(portable_flag)"
assumed_host_libs_json="$(portable_host_libs_json)"
if ((${#nix_auxiliary_overlays[@]} > 0)); then
  nix_auxiliary_overlays_json="$(printf '%s\n' "${nix_auxiliary_overlays[@]}" | python3 -c 'import json,sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin if line.rstrip("\n")]))')"
else
  nix_auxiliary_overlays_json='[]'
fi

# The build command template and derived hash JSON may contain quotes; pass
# them via the environment rather than interpolating them into Python source.
NIX_DERIVED_HASHES_ENV="$derived_hashes_json" \
NIX_BUILD_COMMAND_TEMPLATE_ENV="$NIX_BUILD_COMMAND_TEMPLATE" \
NIX_SOURCE_METADATA_ENV="$source_metadata_json" \
NIX_SOURCE_REPOSITORY_ENV="$source_repository" \
NIX_SOURCE_ARGS_ENV="$nix_source_args_json" \
NIX_AUXILIARY_OVERLAYS_ENV="$nix_auxiliary_overlays_json" \
python3 - "$manifest" "$archive" "$archive_bytes" <<PY
import json
import os
import sys

_, manifest_path, archive_path, archive_bytes_raw = sys.argv
archive_name = os.path.basename(archive_path) if archive_path else None
archive_bytes = int(archive_bytes_raw) if archive_bytes_raw else None
nix_derived_hashes = json.loads(os.environ.get("NIX_DERIVED_HASHES_ENV", "{}"))
source_metadata = json.loads(os.environ.get("NIX_SOURCE_METADATA_ENV", "{}") or "{}")
source_args = json.loads(os.environ.get("NIX_SOURCE_ARGS_ENV", "{}") or "{}")
auxiliary_overlays = json.loads(os.environ.get("NIX_AUXILIARY_OVERLAYS_ENV", "[]") or "[]")

manifest = {
    "service": "$service",
    "version": "$VERSION",
    "platform": "$PLATFORM",
    "arch": "$ARCH",
    "target": "$(artifact_platform_dir "$TARGET_OS" "$ARCH")",
    "libc": "glibc" if "$TARGET_OS" == "linux" else None,
    "source_dir": "$SOURCE_DIR",
    "source_ref": "$SOURCE_REF",
    "source_commit": "$actual_ref",
    "upstream_source": source_metadata or None,
    "upstream_source_repository": os.environ.get("NIX_SOURCE_REPOSITORY_ENV") or None,
    "upstream_image": "$UPSTREAM_IMAGE",
    "base_image": "$BASE_IMAGE",
    "entrypoint": json.loads("""$ENTRYPOINT_JSON"""),
    "cmd": json.loads("""$CMD_JSON"""),
    "build_backend": "nix",
    "nix_flake": "$NIX_FLAKE",
    "nix_flake_for_build": "$nix_flake_for_build",
    "nix_attr": "$NIX_ATTR",
    "nix_source_args": source_args,
    "nix_build_mode": "$NIX_BUILD_MODE",
    "nix_build_command_template": os.environ.get("NIX_BUILD_COMMAND_TEMPLATE_ENV", ""),
    "nix_output_kind": "${NIX_OUTPUT_KIND:-copy-paths}",
    "nix_system": "$NIX_SYSTEM",
    "nix_installable": "$nix_installable",
    "nix_runner": "$resolved_nix_runner",
    "host_nix_system": "$host_nix_system",
    "nix_package_overlay": "$NIX_PACKAGE_OVERLAY",
    "nix_package_overlay_dest": "$NIX_PACKAGE_OVERLAY_DEST",
    "nix_auxiliary_overlays": auxiliary_overlays,
    "nix_derived_hashes": nix_derived_hashes,
    "mix_deps_hash": nix_derived_hashes.get("mix_deps_hash"),
    "nix_copy_paths": ${NIX_COPY_PATHS_JSON:-[]},
    "portable": "$portable" == "true",
    "assumed_host_libs": json.loads("""$assumed_host_libs_json"""),
    "archive_on_build": "${ARTIFACT_ARCHIVE_ON_BUILD:-1}" == "1",
    "excluded_file_classes": [
        "sourcemaps",
        "debug-symbols",
        "tests",
        "docs",
        "examples",
        "package-manager-caches",
        "Next tracing manifests"
    ],
    "smoke_command": "scripts/smoke.sh $service --artifact $rootfs",
    "archive": archive_name,
    "sbom": os.path.basename("$sbom"),
    "licenses": "share/licenses",
    "size": {
        "rootfs_bytes": int($rootfs_kib) * 1024,
        "rootfs_mib": round((int($rootfs_kib) * 1024) / 1024 / 1024, 1),
        "archive_bytes": archive_bytes,
        "archive_mib": round(archive_bytes / 1024 / 1024, 1) if archive_bytes is not None else None
    }
}

with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\\n")
PY

"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs" "$archive"
log "Nix artifact ready: $artifact_dir"
