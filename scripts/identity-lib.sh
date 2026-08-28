#!/usr/bin/env bash
# Shared digest-pin pull + identity probe. Sourced by introspect, image
# build, and pairwise smokes. Requires lib.sh already sourced.

IDENTITY_BUSYBOX_IMAGE="${IDENTITY_BUSYBOX_IMAGE:-busybox:1.36.1}"

cli_volume_path() {
  case "$1" in
    postgres) printf '/var/lib/postgresql/data' ;;
    storage) printf '/mnt' ;;
    edge-runtime) printf '/root' ;;
    *) fail "no CLI volume path for $1" ;;
  esac
}

# Pull one digest-pinned ref. Fail closed — no ECR-first fallback, no
# silent skip. Retries are for throttle, not a different image.
pull_pinned_image() {
  local ref="$1"
  local attempt pulled
  if docker image inspect "$ref" >/dev/null 2>&1; then
    return 0
  fi
  for attempt in 1 2 3; do
    pulled=0
    if [[ -n "${PLATFORM:-}" ]]; then
      docker pull --platform "$PLATFORM" -q "$ref" >/dev/null 2>&1 && pulled=1
    else
      docker pull -q "$ref" >/dev/null 2>&1 && pulled=1
    fi
    if [[ "$pulled" == "1" ]]; then
      return 0
    fi
    log "pull failed for $ref (attempt $attempt/3)"
    if [[ "$attempt" -lt 3 ]]; then
      sleep $((attempt * 20))
    fi
  done
  fail "could not pull pinned upstream image $ref"
}

image_config_user() {
  docker inspect -f '{{.Config.User}}' "$1"
}

# Empty, 0, and root are the same start user (euid 0). Distroless's root
# variant bakes USER 0; docker.io pins leave Config.User empty.
normalize_config_user() {
  case "$1" in
    ""|0|root) printf '' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Official busybox is static. A dynamic host/debian binary cannot exec
# inside an older pin (GLIBC_2.38+).
busybox_is_static() {
  local bin="$1"
  [[ -f "$bin" && ! -d "$bin" && -x "$bin" ]] || return 1
  if command -v file >/dev/null 2>&1; then
    file "$bin" | grep -qi 'statically linked'
    return $?
  fi
  ! ldd "$bin" >/dev/null 2>&1
}

# Static busybox on a Docker-Desktop-visible path (not $TMPDIR: a missing
# bind-mount becomes a directory and `exec /busybox` fails).
identity_busybox_bin() {
  if [[ -n "${IDENTITY_BUSYBOX_BIN:-}" ]] && busybox_is_static "$IDENTITY_BUSYBOX_BIN"; then
    printf '%s' "$IDENTITY_BUSYBOX_BIN"
    return 0
  fi
  local bin cid
  bin="${HOME}/.cache/slim-services/identity-busybox-$(target_arch)"
  if busybox_is_static "$bin"; then
    IDENTITY_BUSYBOX_BIN="$bin"
    printf '%s' "$bin"
    return 0
  fi
  rm -f "$bin"
  mkdir -p "$(dirname "$bin")"
  pull_pinned_image "$IDENTITY_BUSYBOX_IMAGE"
  if [[ -n "${PLATFORM:-}" ]]; then
    cid="$(docker create --platform "$PLATFORM" "$IDENTITY_BUSYBOX_IMAGE")"
  else
    cid="$(docker create "$IDENTITY_BUSYBOX_IMAGE")"
  fi
  docker cp "$cid:/bin/busybox" "$bin"
  docker rm -f "$cid" >/dev/null
  chmod +x "$bin"
  busybox_is_static "$bin" || fail "identity busybox $bin is not statically linked"
  IDENTITY_BUSYBOX_BIN="$bin"
  printf '%s' "$bin"
}

# Run a command inside the pin as root. Prefer the pin's own shell; fall
# back to a bind-mounted static busybox when the pin is shell-less.
# Probe with `:` so a real shell returning 1 (e.g. test -x miss) is not
# treated as "this entrypoint does not exist".
# Extra docker run flags go before `--`:
#   run_in_pin "$ref" -v "$vol:/root" -- sh -c 'echo x > /root/f'
# No `--` means every remaining arg is the command (existing callers).
run_in_pin() {
  local ref="$1"
  shift
  local extra=() cmd=() args=(--rm --user 0)
  local saw_sep=0 arg ep script bb rc
  for arg in "$@"; do
    if [[ "$saw_sep" -eq 0 && "$arg" == "--" ]]; then
      saw_sep=1
      continue
    fi
    if [[ "$saw_sep" -eq 1 ]]; then
      cmd+=("$arg")
    else
      extra+=("$arg")
    fi
  done
  if [[ "$saw_sep" -eq 0 ]]; then
    cmd=("${extra[@]}")
    extra=()
  fi
  [[ ${#cmd[@]} -gt 0 ]] || fail "run_in_pin: missing command"
  if [[ -n "${PLATFORM:-}" ]]; then
    args+=(--platform "$PLATFORM")
  fi
  if [[ ${#extra[@]} -gt 0 ]]; then
    args+=("${extra[@]}")
  fi
  script="$(printf '%q ' "${cmd[@]}")"
  for ep in /bin/bash /usr/bin/bash /bin/sh /usr/bin/sh; do
    if docker run "${args[@]}" --entrypoint "$ep" "$ref" -c ':' >/dev/null 2>&1; then
      rc=0
      docker run "${args[@]}" --entrypoint "$ep" "$ref" -c "$script" || rc=$?
      # 127 = command not found in this shell (slim may lack that applet).
      [[ "$rc" -ne 127 ]] && return "$rc"
    fi
  done
  bb="$(identity_busybox_bin)"
  [[ -f "$bb" && ! -d "$bb" ]] || fail "identity busybox is missing or a directory: $bb"
  docker run "${args[@]}" -v "$bb:/busybox:ro" --entrypoint /busybox "$ref" "${cmd[@]}"
}

# Write identity.env for SERVICE into OUTDIR. Numbers come only from the
# digest-pinned upstream image. DROP_TO_NAME comes from the pin passwd
# line when uid ≠ 0; postgres synthesizes /etc/passwd from DROP_TO_*.
write_upstream_identity() {
  local service="$1"
  local outdir="$2"
  local ref start_user vol_path vol_stat vol_uid vol_gid vol_mode
  local passwd_line drop_uid drop_gid drop_name vol_exists exists_rc

  mkdir -p "$outdir"
  ref="$(pinned_upstream_ref)"
  log "introspecting identity from $ref"
  pull_pinned_image "$ref"

  start_user="$(image_config_user "$ref")"
  vol_path="$(cli_volume_path "$service")"

  vol_stat="$(run_in_pin "$ref" stat -c '%u %g %a' "$vol_path" 2>/dev/null || true)"
  exists_rc=0
  run_in_pin "$ref" test -e "$vol_path" >/dev/null 2>&1 || exists_rc=$?
  case "$exists_rc" in
    0) vol_exists=1 ;;
    1) vol_exists=0 ;;
    *) fail "cannot test $vol_path in $ref (exit $exists_rc)" ;;
  esac
  if [[ -n "$vol_stat" ]]; then
    vol_uid="${vol_stat%% *}"
    vol_gid="$(printf '%s' "$vol_stat" | awk '{print $2}')"
    vol_mode="$(printf '%s' "$vol_stat" | awk '{print $3}')"
  elif [[ "$vol_exists" -eq 1 ]]; then
    fail "cannot stat $vol_path in $ref (path exists)"
  elif [[ "$service" != "storage" ]]; then
    fail "cannot stat $vol_path in $ref"
  elif [[ "$(normalize_config_user "$start_user")" != "" ]]; then
    fail "cannot resolve $vol_path owner in $ref and Config.User is $start_user"
  else
    # /mnt is often absent from the pin (CLI creates the mount). Invent
    # Docker's root-created directory only when the path is missing.
    vol_uid=0
    vol_gid=0
    vol_mode=755
  fi

  drop_uid="$vol_uid"
  drop_gid="$vol_gid"
  if [[ "$drop_uid" == "0" ]]; then
    drop_name="root"
    passwd_line=""
  else
    passwd_line="$(run_in_pin "$ref" cat /etc/passwd | awk -F: -v uid="$drop_uid" '$3==uid {print; exit}')"
    [[ -n "$passwd_line" ]] || fail "no /etc/passwd line for uid $drop_uid in $ref"
    drop_name="${passwd_line%%:*}"
  fi

  {
    printf 'START_USER=%q\n' "$start_user"
    printf 'DROP_TO_UID=%q\n' "$drop_uid"
    printf 'DROP_TO_GID=%q\n' "$drop_gid"
    printf 'DROP_TO_NAME=%q\n' "$drop_name"
    printf 'VOLUME_PATH=%q\n' "$vol_path"
    printf 'VOLUME_UID=%q\n' "$vol_uid"
    printf 'VOLUME_GID=%q\n' "$vol_gid"
    printf 'VOLUME_MODE=%q\n' "$vol_mode"
    printf 'PINNED_IMAGE=%q\n' "$ref"
  } >"$outdir/identity.env"
  log "identity $service: start_user=${start_user:-root} drop=${drop_name}:${drop_uid}:${drop_gid} ${vol_path} ${vol_mode}"
}

load_identity_env() {
  local file="$1"
  [[ -f "$file" ]] || fail "identity.env not found: $file"
  # shellcheck source=/dev/null
  source "$file"
}

# Compare a built slim image to a previously written identity.env.
assert_slim_matches_identity() {
  local slim="$1"
  local identity_file="$2"
  local start_user pin_user vol_path vol_stat
  load_identity_env "$identity_file"

  start_user="$(normalize_config_user "$(image_config_user "$slim")")"
  pin_user="$(normalize_config_user "${START_USER}")"
  [[ "$start_user" == "$pin_user" ]] \
    || fail "slim Config.User '$start_user' != pin '$pin_user'"

  vol_path="${VOLUME_PATH}"
  vol_stat="$(run_in_pin "$slim" stat -c '%u %g %a' "$vol_path" 2>/dev/null || true)"
  [[ -n "$vol_stat" ]] || fail "slim is missing $vol_path"
  [[ "$vol_stat" == "${VOLUME_UID} ${VOLUME_GID} ${VOLUME_MODE}" ]] \
    || fail "slim $vol_path is '$vol_stat', pin is '${VOLUME_UID} ${VOLUME_GID} ${VOLUME_MODE}'"
}

# Sidecar uid from the imgproxy pin Config.User (empty → 0).
imgproxy_sidecar_uid() {
  local ref="${IMGPROXY_UPSTREAM_IMAGE:-ghcr.io/imgproxy/imgproxy:v3.8.0@sha256:75fcf5f5a72bc4bce354d1b5dfb4636a2e6979f0ce68cdacc51ed1bce2ab494e}"
  local user
  if ! docker image inspect "$ref" >/dev/null 2>&1; then
    pull_pinned_image "$ref"
  fi
  user="$(image_config_user "$ref")"
  if [[ -z "$user" || "$user" == "root" ]]; then
    printf '0'
    return 0
  fi
  if [[ "$user" =~ ^[0-9]+$ ]]; then
    printf '%s' "$user"
    return 0
  fi
  # name form: resolve via a one-shot in that image
  run_in_pin "$ref" id -u "$user"
}
