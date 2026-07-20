#!/usr/bin/env bash
# Prep host paths and permissions for rootless Docker OpenBao deploy.
# Assumes Docker is already installed and usable in rootless mode.
set -euo pipefail

APPDATA="${OPENBAO_APPDATA:-/fast/docker-appdata/openbao}"
# Official openbao/openbao runs as uid 100 / gid 1000 (openbao).
CONTAINER_UID=100
CONTAINER_GID=1000

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${SCRIPT_DIR}/config/config.hcl"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

run_priv() {
  # Prefer non-root when possible; fall back to sudo for /fast and chown.
  if [[ -w "$(dirname "$APPDATA")" ]] 2>/dev/null || [[ -w "$APPDATA" ]] 2>/dev/null; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "cannot write under ${APPDATA} (need write access or sudo)"
  fi
}

rootless_host_id() {
  # Rootless mapping: container UID 0 -> host $(id -u);
  # container UID n (n >= 1) -> subuid_start + (n - 1). Same for GIDs.
  # https://docs.docker.com/engine/security/rootless/uid-gid-mapping/
  local kind="$1" container_id="$2"
  local mapfile user start count

  user="$(id -un)"
  case "$kind" in
    uid) mapfile=/etc/subuid ;;
    gid) mapfile=/etc/subgid ;;
    *) die "unknown id kind: $kind" ;;
  esac

  if [[ "$container_id" -eq 0 ]]; then
    if [[ "$kind" == uid ]]; then id -u; else id -g; fi
    return
  fi

  [[ -r "$mapfile" ]] || die "cannot read ${mapfile} (needed for rootless UID/GID mapping)"

  local line
  line="$(grep -E "^${user}:" "$mapfile" | head -n1 || true)"
  [[ -n "$line" ]] || die "no ${mapfile} entry for user '${user}' — rootless Docker requires subordinate IDs"

  start="$(cut -d: -f2 <<<"$line")"
  count="$(cut -d: -f3 <<<"$line")"

  local host_id=$((start + container_id - 1))
  local max=$((start + count - 1))
  if [[ "$host_id" -gt "$max" ]]; then
    die "mapped ${kind} ${host_id} outside subordinate range ${start}-${max}"
  fi
  printf '%s\n' "$host_id"
}

need_cmd docker
need_cmd grep
need_cmd cut
need_cmd head
need_cmd id

[[ -f "$CONFIG_SRC" ]] || die "missing config template: ${CONFIG_SRC}"

if ! docker info >/dev/null 2>&1; then
  die "docker is not usable as $(id -un). Is the rootless daemon running? (e.g. systemctl --user start docker)"
fi

if docker info 2>/dev/null | grep -qi 'rootless:\s*true'; then
  log "detected rootless Docker"
else
  warn "docker info did not report rootless: true — continuing with rootless UID mapping anyway"
fi

HOST_DATA_UID="$(rootless_host_id uid "$CONTAINER_UID")"
HOST_DATA_GID="$(rootless_host_id gid "$CONTAINER_GID")"

log "appdata: ${APPDATA}"
log "data ownership for container ${CONTAINER_UID}:${CONTAINER_GID} → host ${HOST_DATA_UID}:${HOST_DATA_GID}"

log "creating directories"
run_priv mkdir -p "${APPDATA}/config" "${APPDATA}/data"

log "installing config.hcl"
run_priv cp "$CONFIG_SRC" "${APPDATA}/config/config.hcl"
run_priv chmod 644 "${APPDATA}/config/config.hcl"

log "setting data directory ownership and mode"
# chown to subordinate IDs usually requires root even under rootless Docker.
if command -v sudo >/dev/null 2>&1; then
  sudo chown "${HOST_DATA_UID}:${HOST_DATA_GID}" "${APPDATA}/data"
  sudo chmod 700 "${APPDATA}/data"
else
  if chown "${HOST_DATA_UID}:${HOST_DATA_GID}" "${APPDATA}/data" 2>/dev/null; then
    chmod 700 "${APPDATA}/data"
  else
    die "chown ${HOST_DATA_UID}:${HOST_DATA_GID} ${APPDATA}/data failed (install sudo or run as a user that can chown subordinate IDs)"
  fi
fi

log "checking image pull (openbao/openbao:2.6.0)"
if docker pull --quiet openbao/openbao:2.6.0 >/dev/null 2>&1; then
  log "image openbao/openbao:2.6.0 is pullable"
else
  warn "could not pull openbao/openbao:2.6.0 — check network/registry access"
fi

log "prep complete"
printf '\nNext:\n'
printf '  # Compose reads OPENBAO_APPDATA from .env or the environment.\n'
printf '  # Use the same value for prep and compose (default: %s).\n' "$APPDATA"
printf '  cd %s\n' "$SCRIPT_DIR"
printf '  # Optional: cp .env.example .env && edit OPENBAO_APPDATA\n'
printf '  # Optional: export OPENBAO_APPDATA=%s\n' "$APPDATA"
printf '  docker compose up -d\n'
printf '  export BAO_ADDR=http://127.0.0.1:9092\n'
printf '  bao operator init    # first time only; default 5 shares / threshold 3; store offline\n'
printf '  bao operator unseal  # after every restart (Shamir × threshold)\n'
