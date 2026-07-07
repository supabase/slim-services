#!/bin/bash
# Runs as root INSIDE the upstream supabase/postgres image (Nix-based rootfs).
# Builds a pruned copy of the runtime filesystem under /rootfs:
#   - keeps the postgres profile closure via nix-store reference walking
#   - skips heavyweight local-dev-irrelevant packages (deny list below)
#   - drops nix tooling, build derivations, and version-switch scripts
set -euo pipefail

ROOTFS=/rootfs
mkdir -p "$ROOTFS/nix/store"

log() { printf '[prune] %s\n' "$*"; }

# Only Nix tooling and build derivations are excluded. Every extension the
# upstream supabase/postgres image ships stays available: this is the same
# postgres flavour, minus the parts that never execute at runtime.
is_denied() {
  local name="$1"
  case "$name" in
    nix-[0-9]*|nix-man*) return 0 ;;
    *.drv) return 0 ;;
  esac
  return 1
}

top_store_path() {
  # /nix/store/<hash>-<name>/sub/path -> /nix/store/<hash>-<name>
  local p="$1"
  p="${p#/nix/store/}"
  printf '/nix/store/%s' "${p%%/*}"
}

store_name() {
  local p="$1"
  p="${p##*/}"
  printf '%s' "${p#*-}"
}

scan_file_refs() {
  # Extract /nix/store/... references embedded in arbitrary files.
  grep -haoE '/nix/store/[a-z0-9]{32}-[^/ "'"'"':;]*' "$@" 2>/dev/null | sort -u || true
}

declare -A KEEP
queue=()

enqueue() {
  local p
  p="$(top_store_path "$1")"
  [[ -d "$p" || -f "$p" ]] || return 0
  [[ -n "${KEEP[$p]:-}" ]] && return 0
  if is_denied "$(store_name "$p")"; then
    return 0
  fi
  KEEP[$p]=1
  queue+=("$p")
}

log "collecting roots"

# Version-switch developer scripts reference ALTERNATE versions of extensions
# and would drag duplicate store paths into the closure. The default version of
# every extension stays; only the switchable alternates are dropped.
rm -f /usr/lib/postgresql/bin/switch_*_version

root_dirs=(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/lib/postgresql /etc /docker-entrypoint-initdb.d)
for d in "${root_dirs[@]}"; do
  [[ -d "$d" ]] || continue
  while IFS= read -r f; do
    if [[ -L "$f" ]]; then
      t="$(readlink -f "$f" 2>/dev/null || true)"
      [[ "$t" == /nix/store/* ]] && enqueue "$t"
    elif [[ -f "$f" ]]; then
      while IFS= read -r r; do
        [[ -n "$r" ]] && enqueue "$r"
      done < <(scan_file_refs "$f")
    fi
  done < <(find "$d" -type f -o -type l 2>/dev/null)
done

# The active profile (symlink farm over postgres + plugins + tools).
profile_target="$(readlink -f /nix/var/nix/profiles/default)"
enqueue "$profile_target"

log "walking nix store references (roots: ${#queue[@]})"
i=0
while (( i < ${#queue[@]} )); do
  p="${queue[$i]}"
  i=$((i + 1))
  while IFS= read -r ref; do
    [[ -n "$ref" ]] && enqueue "$ref"
  done < <(nix-store --query --references "$p" 2>/dev/null || scan_file_refs "$p"/* 2>/dev/null)
done
log "keep set: ${#KEEP[@]} store paths"

log "copying keep set"
for p in "${!KEEP[@]}"; do
  cp -a "$p" "$ROOTFS/nix/store/"
done

# Profile symlink chain, hop by hop (e.g. default -> per-user/root/profile ->
# profile-N-link -> /nix/store/...-profile). Every intermediate symlink must
# exist in the rootfs or PATH resolution breaks.
p="/nix/var/nix/profiles/default"
hops=0
while [[ -L "$p" && $hops -lt 10 ]]; do
  mkdir -p "$ROOTFS$(dirname "$p")"
  cp -P "$p" "$ROOTFS$p"
  t="$(readlink "$p")"
  case "$t" in
    /*) p="$t" ;;
    *) p="$(dirname "$p")/$t" ;;
  esac
  hops=$((hops + 1))
done

log "copying non-store roots"
# /lib carries the musl loader that /bin/bash and busybox are linked against.
for d in /bin /sbin /lib /lib64 /usr/bin /usr/sbin /usr/local/bin /usr/lib /etc /docker-entrypoint-initdb.d; do
  [[ -e "$d" ]] || continue
  mkdir -p "$ROOTFS$(dirname "$d")"
  cp -a "$d" "$ROOTFS$(dirname "$d")/"
done

rm -rf "$ROOTFS/lib/firmware" "$ROOTFS/lib/apk" "$ROOTFS/lib/modules-load.d" "$ROOTFS/lib/sysctl.d"

chmod -R u+w "$ROOTFS/nix/store" || true

log "sweeping dangling symlinks"
sweep() {
  local removed=1 pass=0
  while (( removed > 0 && pass < 6 )); do
    removed=0
    pass=$((pass + 1))
    while IFS= read -r l; do
      local target="$l" hops=0 t
      while [[ -L "$target" && $hops -lt 12 ]]; do
        t="$(readlink "$target")"
        case "$t" in
          /*) target="$ROOTFS$t" ;;
          *) target="$(dirname "$target")/$t" ;;
        esac
        hops=$((hops + 1))
      done
      if [[ ! -e "$target" ]]; then
        rm -f "$l"
        removed=$((removed + 1))
      fi
    done < <(find "$ROOTFS" -type l)
    log "sweep pass $pass removed $removed dangling links"
  done
}
sweep

log "runtime directories and local-dev config"
# Mirror upstream: /var/run is a symlink to /run so the compile-time psql
# socket dir (/run/postgresql) and unix_socket_directories (/var/run/...)
# resolve to the same place.
mkdir -p "$ROOTFS/var/lib/postgresql" "$ROOTFS/run/postgresql" "$ROOTFS/tmp"
ln -sf ../run "$ROOTFS/var/run"
chmod 1777 "$ROOTFS/tmp"
chmod 0777 "$ROOTFS/run/postgresql"
chown 100:101 "$ROOTFS/var/lib/postgresql" "$ROOTFS/run/postgresql" 2>/dev/null || true

mkdir -p "$ROOTFS/etc/postgresql-custom/conf.d"
cp /overlay/99-local-dev.conf "$ROOTFS/etc/postgresql-custom/conf.d/99-local-dev.conf"

# Docker COPY into the final scratch image strips ownership; the wrapper
# entrypoint restores postgres ownership of /etc/postgresql* at container
# start (running as root before docker-entrypoint.sh gosu-drops).
cp /overlay/slim-entrypoint.sh "$ROOTFS/usr/local/bin/slim-entrypoint.sh"
chmod 0755 "$ROOTFS/usr/local/bin/slim-entrypoint.sh"

du -sh "$ROOTFS/nix/store" "$ROOTFS" || true
log "prune complete"
