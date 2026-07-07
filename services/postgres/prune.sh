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

# Store packages excluded from the local-dev image. Extensions whose .so lives
# inside the postgresql/plugins store paths are additionally deleted by file
# pattern below so nothing dangles at runtime.
is_denied() {
  local name="$1"
  case "$name" in
    postgis-*|sfcgal-*|pgrouting-*|pgroonga-*|supabase-groonga-*|groonga-*) return 0 ;;
    kytea-*|mecab-*|gdal-*|geos-*|proj-[0-9]*|boost-[0-9]*) return 0 ;;
    perl-[0-9]*|wrappers-*|plv8-*|timescaledb-*) return 0 ;;
    nix-[0-9]*|nix-man-*) return 0 ;;
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

# Version-switch developer scripts reference alternate extension versions and
# would drag duplicate store paths into the closure. Remove before scanning.
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

rm -rf "$ROOTFS/usr/lib/groonga" "$ROOTFS/lib/firmware" "$ROOTFS/lib/apk" "$ROOTFS/lib/modules-load.d" "$ROOTFS/lib/sysctl.d"

log "deleting denied extension payloads from copied tree"
chmod -R u+w "$ROOTFS/nix/store" || true
deny_lib_globs=(
  'postgis*' 'address_standardizer*' 'libpgrouting*' 'pgrouting*' 'pgroonga*'
  'plperl*' 'plv8*' 'plls*' 'plcoffee*' 'pljava*' 'wrappers*' 'timescaledb*'
)
deny_ext_globs=(
  'postgis*' 'address_standardizer*' 'pgrouting*' 'pgroonga*'
  'plperl*' 'plperlu*' 'plv8*' 'plls*' 'plcoffee*' 'pljava*' 'wrappers*'
  'timescaledb*'
)
while IFS= read -r libdir; do
  for g in "${deny_lib_globs[@]}"; do
    # shellcheck disable=SC2086
    rm -f "$libdir"/$g 2>/dev/null || true
  done
done < <(find "$ROOTFS/nix/store" -maxdepth 2 -type d -name lib)
while IFS= read -r extdir; do
  for g in "${deny_ext_globs[@]}"; do
    # shellcheck disable=SC2086
    rm -f "$extdir"/$g 2>/dev/null || true
  done
done < <(find "$ROOTFS/nix/store" -type d -path '*share/postgresql/extension')

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

# Docker COPY into the final scratch image strips ownership (everything becomes
# root:root), but postgres itself writes here at startup (pgsodium root key,
# config rewrites by the entrypoint). Permission bits survive COPY; ownership
# does not — so open these up for the local-dev image.
chmod -R 0777 "$ROOTFS/etc/postgresql" "$ROOTFS/etc/postgresql-custom"

du -sh "$ROOTFS/nix/store" "$ROOTFS" || true
log "prune complete"
