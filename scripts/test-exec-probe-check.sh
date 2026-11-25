#!/usr/bin/env bash
# Host-only checks for scripts/exec-probe-check.sh: every registered service
# declares its CLI healthcheck probe, and only exit 125-127 fails the check.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

missing="$(python3 - "$ROOT_DIR" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
services = json.loads((root / ".github/service-release-sources.json").read_text())["services"]
for service in services:
    recipe = root / "services" / service / "recipe.env"
    if not re.search(r"^HEALTHCHECK_PROBE=\S", recipe.read_text(), re.M):
        print(service)
PY
)"
[[ -z "$missing" ]] || { echo "services without HEALTHCHECK_PROBE: $missing" >&2; exit 1; }

mkdir -p "$work_dir/bin"
cat >"$work_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_DOCKER_ARGV"
exit "$FAKE_DOCKER_STATUS"
EOF
chmod +x "$work_dir/bin/docker"
export FAKE_DOCKER_ARGV="$work_dir/argv"

check() {
  rm -f "$FAKE_DOCKER_ARGV"
  FAKE_DOCKER_STATUS="$2" PATH="$work_dir/bin:$PATH" \
    "$ROOT_DIR/scripts/exec-probe-check.sh" "$1" local/test:image >/dev/null 2>&1
}

for status in 0 1 2; do
  check auth "$status" || { echo "probe exit $status must pass" >&2; exit 1; }
done
for expected in --entrypoint --network "exec wget -q --spider http://127.0.0.1:9999/health"; do
  grep -qx -- "$expected" "$FAKE_DOCKER_ARGV" || {
    echo "docker argv lacks '$expected':" >&2; cat "$FAKE_DOCKER_ARGV" >&2; exit 1
  }
done

for status in 125 126 127; do
  if check auth "$status"; then echo "probe exit $status must fail" >&2; exit 1; fi
done

check postgrest 127 || { echo "HEALTHCHECK_PROBE=none must skip docker" >&2; exit 1; }
[[ ! -e "$FAKE_DOCKER_ARGV" ]] || { echo "HEALTHCHECK_PROBE=none ran docker" >&2; exit 1; }

echo "exec-probe-check tests passed"
