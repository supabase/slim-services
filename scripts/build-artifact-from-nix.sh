#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"
# shellcheck source=scripts/nix.sh
source "$ROOT_DIR/scripts/nix.sh"

usage() {
  cat <<'HELP'
Usage: scripts/build-artifact-from-nix.sh SERVICE [VERSION]

Resolve the requested source and dependency hashes, build the root flake's
portable runtime, and export the common artifact layout. Target selection
uses TARGET_OS=linux|darwin and ARCH=arm64|amd64. Nix can use configured
remote builders for targets the current host cannot execute.
HELP
}
[[ "${1:-}" == -h || "${1:-}" == --help ]] && { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
for tool in git tar python3 nix; do require_cmd "$tool"; done

service="$1"
VERSION="${2:-${VERSION:-dev}}"
TARGET_OS="$(target_os)"
ARCH="$(target_arch)"
NIX_SYSTEM="$(nix_system_for "$TARGET_OS" "$ARCH")"
load_recipe "$service"
PLATFORM="$TARGET_OS/$ARCH"
artifact_dir="$(dirname "$(artifact_rootfs_path "$service" "$VERSION" "$TARGET_OS" "$ARCH")")"
rootfs="$artifact_dir/rootfs"
manifest="$artifact_dir/manifest.json"
sbom="$artifact_dir/$service-$VERSION-$(artifact_platform_dir "$TARGET_OS" "$ARCH").sbom.spdx.json"
mkdir -p "$artifact_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/slim-nix-release.XXXXXX")"
release_dir="$work_dir/release"
mkdir -p "$release_dir"
trap 'rm -rf "$work_dir"' EXIT

source_metadata='{}'
source_repository=''
actual_ref=''
if [[ -n "${UPSTREAM_ASSETS_FILE:-}" ]]; then
  snapshot="$UPSTREAM_ASSETS_FILE"
  [[ "$snapshot" = /* ]] || snapshot="$ROOT_DIR/$snapshot"
  source_metadata="$(python3 "$ROOT_DIR/scripts/upstream-release.py" source "$snapshot" "$VERSION")"
  source_repository="$(python3 - "$snapshot" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["repository"])
PY
  )"
  actual_ref="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["commit"])' "$source_metadata")"
else
  source_abs="$ROOT_DIR/${SOURCE_DIR:?recipe must define SOURCE_DIR}"
  [[ -e "$source_abs/.git" ]] || fail "source is not a Git checkout: $source_abs"
  expected_ref="$(resolve_source_ref "$source_abs" "${SOURCE_REF:?recipe must define SOURCE_REF}")"
  actual_ref="$(git -C "$source_abs" rev-parse HEAD)"
  [[ "$actual_ref" == "$expected_ref" ]] || fail "$SOURCE_DIR is at $actual_ref, expected $SOURCE_REF ($expected_ref)"
  [[ -z "$(git -C "$source_abs" status --porcelain)" ]] || fail "$SOURCE_DIR has local modifications"
  source_repository="$(git -C "$source_abs" remote get-url origin 2>/dev/null || true)"
  mkdir -p "$release_dir/source"
  git -C "$source_abs" archive HEAD | tar -C "$release_dir/source" -xf -
fi

python3 - "$release_dir/release.json" "$service" "$VERSION" "$actual_ref" "$source_repository" "$source_metadata" <<'PY'
import json, sys
path, service, version, commit, repository, source_raw = sys.argv[1:]
source = json.loads(source_raw)
hashes = {"vendorHash": source["vendorHash"]} if "vendorHash" in source else {}
release = {"service": service, "version": version, "sourceCommit": commit,
           "sourceRepository": repository, "source": source, "hashes": hashes}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(release, stream, indent=2)
    stream.write("\n")
PY

case "$service" in
  pgmeta|storage|studio)
    node_source="$release_dir/source"
    [[ "$service" == studio ]] && node_source="$node_source/apps/studio"
    node_major="$(upstream_node_major "$node_source" "$release_dir/source")"
    manager_version=''
    framework=''
    if [[ "$service" == storage ]]; then
      manager_version="$(upstream_package_manager_version "$release_dir/source" npm)"
    elif [[ "$service" == studio ]]; then
      manager_version="$(upstream_package_manager_version "$release_dir/source" pnpm)"
      framework="$(upstream_docker_arg "$node_source" STUDIO_FRAMEWORK)"
    fi
    python3 - "$release_dir/release.json" "$node_major" "$manager_version" "$framework" <<'PYMETA'
import json, sys
path, major, manager, framework = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)
data["nodeMajor"] = int(major)
if data["service"] == "storage":
    data["npmVersion"] = manager
elif data["service"] == "studio":
    data["pnpmVersion"] = manager
    data["studioFramework"] = framework
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
PYMETA
    ;;
esac

if [[ "$service" == postgrest ]]; then
  python3 - "$release_dir/release.json" "${UPSTREAM_ASSET_URL:-}" "${UPSTREAM_ASSET_SHA256:-}" <<'PYASSET'
import base64, json, re, sys, urllib.request
path, url, digest = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    data = json.load(stream)
version = data["version"]
name = f"postgrest-{version}-macos-aarch64.tar.xz"
expected = f"https://github.com/PostgREST/postgrest/releases/download/{version}/{name}"
if not url or not digest:
    request = urllib.request.Request(f"https://api.github.com/repos/PostgREST/postgrest/releases/tags/{version}", headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request) as response:
        assets = [a for a in json.load(response)["assets"] if a["name"] == name]
    if len(assets) != 1:
        raise SystemExit(f"expected one PostgREST release asset {name}")
    url, digest = assets[0]["browser_download_url"], assets[0].get("digest", "").removeprefix("sha256:")
if url != expected or re.fullmatch("[0-9a-f]{64}", digest) is None:
    raise SystemExit("invalid PostgREST release asset URL or SHA-256")
data.update(assetUrl=url, assetHash="sha256-" + base64.b64encode(bytes.fromhex(digest)).decode("ascii"))
with open(path, "w", encoding="utf-8") as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
PYASSET
fi

# Discovery belongs to release resolution: each probe fixes one dependency
# input for this exact source and target. The final build consumes those
# explicit hashes with pure evaluation, including on a future automated release.
probe_keys="$(nix_release eval "$release_dir" "legacyPackages.$NIX_SYSTEM.probeOrder" --json)"
while IFS= read -r hash_key; do
  [[ -n "$hash_key" ]] || continue
  if python3 - "$release_dir/release.json" "$hash_key" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    raise SystemExit(0 if sys.argv[2] in json.load(stream)["hashes"] else 1)
PY
  then
    continue
  fi
  log "resolving $service $VERSION dependency $hash_key for $NIX_SYSTEM"
  resolved_hash="$(nix_probe_hash "$release_dir" "$NIX_SYSTEM" "$hash_key")"
  python3 - "$release_dir/release.json" "$hash_key" "$resolved_hash" <<'PYHASH'
import json, sys
path, key, value = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    release = json.load(stream)
release["hashes"][key] = value
with open(path, "w", encoding="utf-8") as stream:
    json.dump(release, stream, indent=2)
    stream.write("\n")
PYHASH
done < <(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])))' "$probe_keys")

log "building $service $VERSION runtime with locked release inputs for $NIX_SYSTEM"
runtime="$(nix_release build "$release_dir" "packages.$NIX_SYSTEM.runtime" --no-link --print-out-paths)"
[[ -d "$runtime" ]] || fail "Nix did not return a runtime directory: $runtime"
if [[ -d "$rootfs" ]]; then chmod -R u+w "$rootfs"; fi
rm -rf "$rootfs"
mkdir -p "$rootfs"
cp -R "$runtime"/. "$rootfs/"
chmod -R u+w "$rootfs"

# Darwin's system signer is the documented final portability boundary. Verify
# exported signatures with the host tool before auditing/archiving the bytes.
if [[ "$TARGET_OS" == darwin && "$(host_os)" == darwin ]]; then
  while IFS= read -r -d '' macho; do
    file "$macho" | grep -q 'Mach-O' || continue
    if ! /usr/bin/codesign --verify "$macho" >/dev/null 2>&1; then
      /usr/bin/codesign --force --sign - "$macho"
    fi
  done < <(find "$rootfs" -type f -print0)
fi
if [[ "$service" == studio ]]; then
  "$ROOT_DIR/services/studio/validate-artifact.sh" "$rootfs"
fi
"$ROOT_DIR/scripts/generate-artifact-sbom.sh" "$rootfs" "$sbom" "$service" "$VERSION" "$(artifact_platform_dir "$TARGET_OS" "$ARCH")"

python3 - "$manifest" "$release_dir/release.json" "$PLATFORM" "$(artifact_platform_dir "$TARGET_OS" "$ARCH")" \
  "${SOURCE_DIR:-}" "${SOURCE_REF:-}" "${UPSTREAM_IMAGE:-${SOURCE_IMAGE:-}}" \
  "${ENTRYPOINT_JSON:-[]}" "${CMD_JSON:-[]}" "$(portable_flag)" "$(portable_host_libs_json)" \
  "$sbom" "$NIX_SYSTEM" "$runtime" "$(du -sk "$rootfs" | awk '{print $1}')" <<'PY'
import json, os, sys
(path, release_path, platform, target, source_dir, source_ref, upstream_image,
 entrypoint, cmd, portable, host_libs, sbom, system, runtime, rootfs_kib) = sys.argv[1:]
with open(release_path, encoding="utf-8") as stream:
    release = json.load(stream)
rootfs_bytes = int(rootfs_kib) * 1024
manifest = {
    "service": release["service"], "version": release["version"],
    "platform": platform, "arch": platform.split("/")[1], "target": target,
    "libc": "glibc" if platform.startswith("linux/") else None,
    "source_dir": source_dir or None, "source_ref": source_ref or None,
    "source_commit": release["sourceCommit"], "upstream_image": upstream_image,
    "upstream_source": release["source"] or None,
    "upstream_source_repository": release["sourceRepository"] or None,
    "base_image": "scratch", "entrypoint": json.loads(entrypoint), "cmd": json.loads(cmd),
    "build_backend": "nix", "nix_flake": ".", "nix_attr": "runtime",
    "nix_system": system, "nix_derived_hashes": release["hashes"],
    "nix_release": release, "nix_runtime": runtime,
    "portable": portable == "true", "assumed_host_libs": json.loads(host_libs),
    "archive": None, "archive_on_build": False,
    "sbom": os.path.basename(sbom), "licenses": "share/licenses",
    "size": {"rootfs_bytes": rootfs_bytes, "rootfs_mib": round(rootfs_bytes / 1024**2, 1),
             "archive_bytes": None, "archive_mib": None},
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream, indent=2)
    stream.write("\n")
PY
if [[ "$service" == studio ]]; then
  "$ROOT_DIR/services/studio/validate-artifact.sh" "$rootfs" "$manifest"
fi
if [[ "${ARTIFACT_ARCHIVE_ON_BUILD:-1}" == 1 ]]; then
  "$ROOT_DIR/scripts/archive-artifact.sh" "$rootfs" "$artifact_dir/$service"
fi
"$ROOT_DIR/scripts/measure-artifact.sh" "$rootfs"
log "Nix artifact ready: $artifact_dir"
