#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT_DIR/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/update-results-tables.sh [--allow-missing] [--host-native-only]

Regenerate the results tables in README.md and SLIM_IMAGES_REPORT.md from the
latest artifacts/<service>/*/linux-arm64/manifest.json files (slim size, idle
RSS, idle CPU) and upstream compressed sizes fetched live with
`docker buildx imagetools inspect`. Also regenerates the host-native
darwin-arm64 table in README.md from darwin-arm64 manifests (services without
one are simply omitted).

Content is spliced between these marker comments, which must exist:
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
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
allow_missing=0
host_native_only=0
merge=0
for arg in "$@"; do
  case "$arg" in
    --allow-missing) allow_missing=1 ;;
    --host-native-only) host_native_only=1 ;;
    --merge) merge=1 ;;
    *) usage >&2; exit 2 ;;
  esac
done

require_cmd python3
[[ "$host_native_only" == "1" ]] || require_cmd docker

# Table order and display names (core services first, opt-ins last).
ordered_services=(postgres postgrest auth realtime storage edge-runtime studio analytics pgmeta pooler)
display_names=("Postgres" "PostgREST" "Auth" "Realtime" "Storage" "Edge Runtime" "Studio" "Analytics" "PgMeta" "Pooler")

rows_tsv=""
for i in "${!ordered_services[@]}"; do
  service="${ordered_services[$i]}"
  display="${display_names[$i]}"
  recipe_vars="$(
    # shellcheck disable=SC1090
    source "$(recipe_file "$service")" >/dev/null 2>&1
    printf '%s\t%s\t%s\n' "${UPSTREAM_IMAGE:-}" "${UPSTREAM_COMPARE_IMAGE:-}" "${RESULTS_NOTE:-}"
  )"
  rows_tsv+="$service"$'\t'"$display"$'\t'"$recipe_vars"$'\n'
done

# Host-native darwin-arm64 table: driven by darwin manifests only; services
# without one are omitted (or, with --merge, keep their existing row).
ROWS_TSV="$rows_tsv" MERGE="$merge" python3 - "$ROOT_DIR" <<'PY'
import glob
import json
import os
import re
import sys

root = sys.argv[1]
merge = os.environ.get("MERGE") == "1"

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
    service, display = line.split("\t")[:2]

    manifests = glob.glob(os.path.join(root, "artifacts", service, "*", "darwin-arm64", "manifest.json"))
    if not manifests:
        if merge and display in kept:
            rows.append(kept[display])
        continue
    manifest_path = max(manifests, key=os.path.getmtime)
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    version = manifest.get("version", "?")
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
    rows.append(
        f"| {display} | `{version}` | {archive_cell} | {rootfs_cell} "
        f"| {rss_cell} | {cpu_cell} | {portable_cell} "
        f"| [report](services/{service}/REPORT.md) |"
    )

if rows:
    header = (
        "| Service | Version | Archive | rootfs | Idle RSS | Idle CPU | Portable | Report |\n"
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
ROWS_TSV="$rows_tsv" MERGE="$merge" python3 - "$ROOT_DIR" "$allow_missing" <<'PY'
import glob
import json
import os
import re
import subprocess
import sys

root, allow_missing = sys.argv[1], sys.argv[2] == "1"
merge = os.environ.get("MERGE") == "1"

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
    service, display, upstream_image, compare_image, note = (line.split("\t") + [""] * 5)[:5]

    manifests = glob.glob(os.path.join(root, "artifacts", service, "*", "linux-arm64", "manifest.json"))
    if not manifests:
        if merge and display in kept:
            rows.append(kept[display])
            continue
        msg = f"no linux-arm64 manifest for {service}; build it first (scripts/ci-build-service.sh {service} <version>)"
        if allow_missing or merge:
            print(f"[tables] WARNING: {msg}", file=sys.stderr)
            continue
        raise SystemExit(f"[tables] ERROR: {msg}")
    manifest_path = max(manifests, key=os.path.getmtime)
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)

    version = manifest.get("version", "?")
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

    version_cell = f"`{version}`" + (f" ({note})" if note else "")
    rss_cell = f"`{rss:.1f} MiB`" if rss is not None else "—"
    cpu_cell = f"`{cpu:.2f}%`" if cpu is not None else "—"
    rows.append(
        f"| {display} | {version_cell} | `{up:.1f} MiB`{star} | `{slim_mib:.1f} MiB` "
        f"| `{reduction:.1f}%`{star} | {rss_cell} | {cpu_cell} "
        f"| [report](services/{service}/REPORT.md) |"
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
    "| Service | Version | Upstream ARM64 | Current slim | Reduction | Idle RSS | Idle CPU | Report |\n"
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
    f"| Upstream ARM64 images total ({len(rows)} services) | `{total_upstream:.1f} MiB` |\n"
    f"| Current slim images total | `{total_slim:.1f} MiB` |\n"
    f"| Current total reduction vs upstream | `{saved:.1f} MiB / {saved / total_upstream * 100:.1f}%` |"
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
splice(os.path.join(root, "SLIM_IMAGES_REPORT.md"), "results", table)
splice(os.path.join(root, "SLIM_IMAGES_REPORT.md"), "totals", totals)
PY

log "results tables regenerated"
