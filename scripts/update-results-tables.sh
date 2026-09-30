#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/update-results-tables.sh [--allow-missing] [--host-native-only]
                                        [--merge] [--published]

Regenerate the results tables in README.md and SLIM_IMAGES_REPORT.md from the
latest artifacts/<service>/*/linux-arm64/manifest.json files (slim size, idle
RSS, idle CPU) and upstream compressed sizes fetched live with
`docker buildx imagetools inspect`. Also regenerates the host-native
darwin-arm64 table in README.md from darwin-arm64 manifests (services without
one are simply omitted).

Content is spliced between these marker comments, which must exist:
  <!-- generated:release-summary:begin --> ... <!-- generated:release-summary:end -->
  <!-- generated:totals:begin -->      ... <!-- generated:totals:end -->
  <!-- generated:results:begin -->     ... <!-- generated:results:end -->
  <!-- generated:host-native:begin --> ... <!-- generated:host-native:end -->

Recipe variables consumed per service:
  UPSTREAM_IMAGE          upstream reference for the size comparison
  UPSTREAM_COMPARE_IMAGE  override when the exact tag is not published
                          (renders the upstream columns with a `*`)
  RESULTS_NOTE            short note appended to the version cell

--allow-missing skips services without a local linux-arm64 manifest instead of
failing.
--host-native-only only regenerates the host-native table (darwin rebuilds do
not change the Linux image numbers, and regenerating those requires all Linux
artifacts locally plus registry access).
--merge updates only the rows for services with local manifests and keeps the
existing table rows (and their upstream sizes) for everything else; totals are
recomputed from the final row set. This is the CI mode: a partial
service-artifacts.yml dispatch refreshes just the rows it rebuilt.
--published updates only README.md, labels the table as published results, and
links each generated row to its GitHub release. Use it with manifests downloaded
from this repository's latest releases and --merge.

Set RESULTS_ARTIFACTS_DIR to read manifests from a directory other than the
repository's ignored artifacts/ directory.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
allow_missing=0
host_native_only=0
merge=0
published=0
for arg in "$@"; do
  case "$arg" in
    --allow-missing) allow_missing=1 ;;
    --host-native-only) host_native_only=1 ;;
    --merge) merge=1 ;;
    --published) published=1 ;;
    *) usage >&2; exit 2 ;;
  esac
done

require_cmd python3
[[ "$host_native_only" == "1" ]] || require_cmd docker
ARTIFACTS_DIR="${RESULTS_ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"

# Table order and display names (core services first, opt-ins last).
ordered_services=(postgres postgrest auth realtime storage edge-runtime studio analytics pgmeta pooler)
display_names=("Postgres" "PostgREST" "Auth" "Realtime" "Storage" "Edge Runtime" "Studio" "Analytics" "PgMeta" "Pooler")

rows_tsv=""
ORDERED_SERVICES="$(IFS=,; printf '%s' "${ordered_services[*]}")"
DISPLAY_NAMES="$(IFS=$'\t'; printf '%s' "${display_names[*]}")"
# A failed selection must stop the run, not render empty tables.
release_rows="$(
  ORDERED_SERVICES="$ORDERED_SERVICES" DISPLAY_NAMES="$DISPLAY_NAMES" \
    python3 - "$ROOT_DIR" "$ARTIFACTS_DIR" <<'PY'
import glob
import json
import os
import re
import sys

root, artifacts_dir = sys.argv[1:]
with open(os.path.join(root, ".github", "service-release-sources.json"), encoding="utf-8") as fh:
    release_config = json.load(fh)["services"]
services = os.environ["ORDERED_SERVICES"].split(",")
displays = os.environ["DISPLAY_NAMES"].split("\t")

def version_key(value):
    return tuple(
        (0, int(part)) if part.isdigit() else (1, part)
        for part in re.findall(r"\d+|\D+", value)
    )

def manifest_entry(path):
    """(upstream version, revision, artifacts/<service>/<dir> name) of a platform manifest."""
    with open(path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    version_dir = os.path.basename(os.path.dirname(os.path.dirname(path)))
    return manifest.get("upstream_version"), manifest.get("revision", 0), version_dir

def platform_manifests(service, platform):
    """Revision manifest entries, oldest mtime first. Legacy manifests without
    upstream_version are frozen history."""
    paths = glob.glob(os.path.join(artifacts_dir, service, "*", platform, "manifest.json"))
    entries = [manifest_entry(path) for path in sorted(paths, key=os.path.getmtime)]
    return [entry for entry in entries if entry[0]]

def newest_in_line(entries, pattern):
    matched = [entry for entry in entries if pattern.fullmatch(entry[0])]
    return max(matched, key=lambda entry: (version_key(entry[0]), entry[1])) if matched else None

def postgres_line_label(pattern):
    if "orioledb" in pattern:
        return "Postgres OrioleDB"
    if pattern.startswith("^15"):
        return "Postgres 15"
    if pattern.startswith("^17"):
        return "Postgres 17"
    return "Postgres"

# Each platform table reads its own newest manifest independently.
for service, display in zip(services, displays):
    linux = platform_manifests(service, "linux-arm64")
    darwin = platform_manifests(service, "darwin-arm64")
    lines = release_config.get(service, {}).get("release_lines")
    if not lines:
        selected = [(display, linux[-1] if linux else None, darwin[-1] if darwin else None)]
    else:
        selected = []
        for line in lines:
            pattern = re.compile(line["tag_pattern"])
            label = postgres_line_label(line["tag_pattern"]) if service == "postgres" else display
            selected.append(
                (label, newest_in_line(linux, pattern), newest_in_line(darwin, pattern))
            )
    for label, linux_entry, darwin_entry in selected:
        upstream = (linux_entry or darwin_entry or ("",))[0]
        print(
            service,
            label,
            upstream,
            linux_entry[2] if linux_entry else "",
            darwin_entry[2] if darwin_entry else "",
            sep="\x1f",
        )
PY
)"
# Unit-separated: tab is IFS whitespace, so read would merge empty fields.
while IFS=$'\x1f' read -r service display upstream_version linux_dir darwin_dir; do
  [[ -n "$service" ]] || continue
  recipe_vars="$(
    SOURCE_REF="$upstream_version"
    VERSION="$upstream_version"
    # shellcheck disable=SC1090
    source "$(recipe_file "$service")" >/dev/null 2>&1
    printf '%s\t%s\t%s' "${UPSTREAM_IMAGE:-}" "${UPSTREAM_COMPARE_IMAGE:-}" "${RESULTS_NOTE:-}"
  )"
  rows_tsv+="$service"$'\t'"$display"$'\t'"$recipe_vars"$'\t'"$linux_dir"$'\t'"$darwin_dir"$'\n'
done <<< "$release_rows"

# Host-native darwin-arm64 table: driven by darwin manifests only; services
# without one are omitted (or, with --merge, keep their existing row).
ROWS_TSV="$rows_tsv" MERGE="$merge" PUBLISHED="$published" \
  ARTIFACTS_DIR="$ARTIFACTS_DIR" \
  RESULTS_REPOSITORY="${RELEASE_RESULTS_REPOSITORY:-${GITHUB_REPOSITORY:-supabase/slim-services}}" \
  python3 - "$ROOT_DIR" <<'PY'
import glob
import json
import os
import re
import sys

root = sys.argv[1]
merge = os.environ.get("MERGE") == "1"
published = os.environ.get("PUBLISHED") == "1"
results_repository = os.environ["RESULTS_REPOSITORY"]
artifacts_dir = os.environ["ARTIFACTS_DIR"]

def existing_rows(path, marker):
    """display name -> existing table row inside the marker block."""
    begin, end = f"<!-- generated:{marker}:begin -->", f"<!-- generated:{marker}:end -->"
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if begin not in text or end not in text:
        return {}
    block = text.split(begin, 1)[1].split(end, 1)[0]
    rows = {}
    for line in block.splitlines():
        m = re.match(r"^\| ([^|]+?) \| `", line)
        if m:
            rows[m.group(1)] = line
    return rows

kept = existing_rows(os.path.join(root, "README.md"), "host-native") if merge else {}

rows = []
for line in os.environ["ROWS_TSV"].splitlines():
    if not line.strip():
        continue
    service, display, _, _, _, _, darwin_dir = (line.split("\t") + [""] * 7)[:7]

    manifest_path = (
        os.path.join(artifacts_dir, service, darwin_dir, "darwin-arm64", "manifest.json")
        if darwin_dir
        else ""
    )
    if not manifest_path or not os.path.isfile(manifest_path):
        if merge and display in kept:
            rows.append(kept[display])
        continue
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    release_version = manifest.get("version", "?")
    upstream_version = manifest.get("upstream_version", release_version)
    size = manifest.get("size") or {}
    archive_mib = size.get("archive_mib")
    rootfs_mib = size.get("rootfs_mib")
    runtime = manifest.get("runtime") or {}
    rss = runtime.get("runtime_rss_mib")
    cpu = runtime.get("idle_cpu_pct")
    portable = manifest.get("portable")

    archive_cell = f"`{archive_mib:.1f} MiB`" if archive_mib is not None else "—"
    rootfs_cell = f"`{rootfs_mib:.1f} MiB`" if rootfs_mib is not None else "—"
    rss_cell = f"`{rss:.1f} MiB`" if rss is not None else "—"
    cpu_cell = f"`{cpu:.2f}%`" if cpu is not None else "—"
    portable_cell = "yes" if portable else "**no**"
    sources = f"[report](services/{service}/REPORT.md)"
    if published:
        release_tag = f"{service}-{release_version}"
        sources = (
            f"[release](https://github.com/{results_repository}/releases/tag/{release_tag})"
            f" · {sources}"
        )
    rows.append(
        f"| {display} | `{upstream_version}` | {archive_cell} | {rootfs_cell} "
        f"| {rss_cell} | {cpu_cell} | {portable_cell} "
        f"| {sources} |"
    )

if rows:
    header = (
        f"| Service | Version | Archive | rootfs | Idle RSS | Idle CPU | Portable | {'Sources' if published else 'Report'} |\n"
        "|---|---:|---:|---:|---:|---:|---|---|"
    )
    table = header + "\n" + "\n".join(rows)
else:
    table = "_No darwin-arm64 artifacts built yet._"

def splice(path, marker, content):
    begin, end = f"<!-- generated:{marker}:begin -->", f"<!-- generated:{marker}:end -->"
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if begin not in text or end not in text:
        raise SystemExit(f"[tables] ERROR: markers {begin} / {end} not found in {path}")
    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(head + begin + "\n" + content + "\n" + end + tail)
    print(f"[tables] updated {os.path.relpath(path, root)} ({marker})", file=sys.stderr)

splice(os.path.join(root, "README.md"), "host-native", table)
PY

if [[ "$host_native_only" == "1" ]]; then
  log "host-native results table regenerated"
  exit 0
fi

# Rows travel via the environment: python reads its program from stdin (the
# heredoc), so stdin cannot also carry the data.
ROWS_TSV="$rows_tsv" MERGE="$merge" PUBLISHED="$published" \
  ARTIFACTS_DIR="$ARTIFACTS_DIR" \
  RESULTS_REPOSITORY="${RELEASE_RESULTS_REPOSITORY:-${GITHUB_REPOSITORY:-supabase/slim-services}}" \
  python3 - "$ROOT_DIR" "$allow_missing" <<'PY'
import glob
import json
import os
import re
import subprocess
import sys

root, allow_missing = sys.argv[1], sys.argv[2] == "1"
merge = os.environ.get("MERGE") == "1"
published = os.environ.get("PUBLISHED") == "1"
results_repository = os.environ["RESULTS_REPOSITORY"]
artifacts_dir = os.environ["ARTIFACTS_DIR"]

def existing_rows(path, marker):
    begin, end = f"<!-- generated:{marker}:begin -->", f"<!-- generated:{marker}:end -->"
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if begin not in text or end not in text:
        return {}
    block = text.split(begin, 1)[1].split(end, 1)[0]
    rows = {}
    for line in block.splitlines():
        m = re.match(r"^\| ([^|]+?) \| `", line)
        if m:
            rows[m.group(1)] = line
    return rows

kept = existing_rows(os.path.join(root, "README.md"), "results") if merge else {}

def row_mib(row, col):
    """Parse the MiB value out of table column `col` of a generated row."""
    cells = [c.strip() for c in row.split("|")]
    m = re.search(r"([0-9.]+) MiB", cells[col])
    return float(m.group(1)) if m else None

def upstream_mib(image_ref):
    """Sum of compressed arm64 layer sizes for an image reference."""
    def raw(ref):
        out = subprocess.run(
            ["docker", "buildx", "imagetools", "inspect", ref, "--raw"],
            capture_output=True, text=True, timeout=120,
        )
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip())
        return json.loads(out.stdout)

    m = raw(image_ref)
    if "manifests" in m:
        digests = [
            x["digest"] for x in m["manifests"]
            if x.get("platform", {}).get("architecture") == "arm64"
            and x.get("platform", {}).get("os") == "linux"
        ]
        if not digests:
            raise RuntimeError(f"no linux/arm64 manifest in {image_ref}")
        m = raw(f"{image_ref.split(':')[0]}@{digests[0]}")
    return sum(layer["size"] for layer in m["layers"]) / 1048576

rows = []
total_upstream = 0.0
total_slim = 0.0
directional = False

for line in os.environ["ROWS_TSV"].splitlines():
    if not line.strip():
        continue
    service, display, upstream_image, compare_image, note, linux_dir, _ = (line.split("\t") + [""] * 7)[:7]

    manifest_path = (
        os.path.join(artifacts_dir, service, linux_dir, "linux-arm64", "manifest.json")
        if linux_dir
        else ""
    )
    if not manifest_path or not os.path.isfile(manifest_path):
        if merge and display in kept:
            rows.append(kept[display])
            continue
        msg = f"no linux-arm64 manifest for {service}; build it first (scripts/ci-build-service.sh {service} <version>)"
        if allow_missing or merge:
            print(f"[tables] WARNING: {msg}", file=sys.stderr)
            continue
        raise SystemExit(f"[tables] ERROR: {msg}")
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    release_version = manifest.get("version", "?")
    upstream_version = manifest.get("upstream_version", release_version)
    image = manifest.get("image") or {}
    slim_mib = image.get("gzip_mib")
    runtime = manifest.get("runtime") or {}
    rss = runtime.get("runtime_rss_mib")
    cpu = runtime.get("idle_cpu_pct")
    if slim_mib is None:
        msg = f"{manifest_path} has no image.gzip_mib; run the full ci-build for {service}"
        if merge:
            print(f"[tables] WARNING: {msg} — keeping existing row", file=sys.stderr)
            if display in kept:
                rows.append(kept[display])
            continue
        raise SystemExit(f"[tables] ERROR: {msg}")

    ref = compare_image or upstream_image
    star = "*" if compare_image else ""
    print(f"[tables] fetching upstream size for {service}: {ref}", file=sys.stderr)
    up = upstream_mib(ref)

    reduction = (1 - slim_mib / up) * 100

    version_cell = f"`{upstream_version}`" + (f" ({note})" if note else "")
    rss_cell = f"`{rss:.1f} MiB`" if rss is not None else "—"
    cpu_cell = f"`{cpu:.2f}%`" if cpu is not None else "—"
    sources = f"[report](services/{service}/REPORT.md)"
    if published:
        release_tag = f"{service}-{release_version}"
        sources = (
            f"[release](https://github.com/{results_repository}/releases/tag/{release_tag})"
            f" · {sources}"
        )
    rows.append(
        f"| {display} | {version_cell} | `{up:.1f} MiB`{star} | `{slim_mib:.1f} MiB` "
        f"| `{reduction:.1f}%`{star} | {rss_cell} | {cpu_cell} "
        f"| {sources} |"
    )

# Totals + the directional marker come from the FINAL row set (fresh and
# kept rows alike), so --merge keeps them truthful.
for row in rows:
    up = row_mib(row, 3)
    slim = row_mib(row, 4)
    if up is not None and slim is not None:
        total_upstream += up
        total_slim += slim
    if "MiB`*" in row:
        directional = True

header = (
    f"| Service | Version | Upstream ARM64 | {'Published slim' if published else 'Current slim'} "
    f"| Reduction | Idle RSS | Idle CPU | {'Sources' if published else 'Report'} |\n"
    "|---|---:|---:|---:|---:|---:|---:|---|"
)
table = header + "\n" + "\n".join(rows)
if directional:
    table += (
        "\n\n`*` Upstream comparison uses `UPSTREAM_COMPARE_IMAGE` from the recipe"
        " (the exact tag is not published on Docker Hub), so the percentage is"
        " directional."
    )

saved = total_upstream - total_slim
totals = (
    "| Metric | Compressed size |\n"
    "|---|---:|\n"
    f"| Upstream ARM64 images total ({len(rows)} rows) | `{total_upstream:.1f} MiB` |\n"
    f"| Current slim images total | `{total_slim:.1f} MiB` |\n"
    f"| Current total reduction vs upstream | `{saved:.1f} MiB / {saved / total_upstream * 100:.1f}%` |"
)

release_summary = (
    f"For the latest published Linux ARM64 release set ({len(rows)} rows), upstream images\n"
    f"total **{total_upstream:.1f} MiB** compressed; the slim set totals **{total_slim:.1f} MiB** "
    f"(**{saved / total_upstream * 100:.1f}%**\n"
    "smaller — exact numbers below). Every published service also has measured\n"
    "steady-state RSS and idle-CPU numbers. These isolated service smoke\n"
    "measurements do not establish complete Dockerless CLI-stack behavior or a\n"
    "25-parallel-stack capacity result."
)

def splice(path, marker, content):
    begin, end = f"<!-- generated:{marker}:begin -->", f"<!-- generated:{marker}:end -->"
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if begin not in text or end not in text:
        raise SystemExit(f"[tables] ERROR: markers {begin} / {end} not found in {path}")
    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(head + begin + "\n" + content + "\n" + end + tail)
    print(f"[tables] updated {os.path.relpath(path, root)} ({marker})", file=sys.stderr)

splice(os.path.join(root, "README.md"), "results", table)
if published:
    splice(os.path.join(root, "README.md"), "release-summary", release_summary)
if not published:
    splice(os.path.join(root, "SLIM_IMAGES_REPORT.md"), "results", table)
    splice(os.path.join(root, "SLIM_IMAGES_REPORT.md"), "totals", totals)
PY

log "results tables regenerated"
