#!/usr/bin/env bash
# Prep host for Linkwarden (data dirs, .env, Docker/DHI checks).
# Assumes Docker is already installed and configured (rootless or rootful).
#
# Override the data root:
#   LINKWARDEN_DATA_ROOT=/path/to/data ./setup.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINKWARDEN_DATA_ROOT="${LINKWARDEN_DATA_ROOT:-/fast/docker-appdata/linkwarden}"
POSTGRES_DIR="${LINKWARDEN_DATA_ROOT}/postgres"
MEILI_DIR="${LINKWARDEN_DATA_ROOT}/meilisearch"
LINKWARDEN_DIR="${LINKWARDEN_DATA_ROOT}/linkwarden"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
DHI_IMAGE="dhi.io/postgres:16-alpine3.23"
PG_CONTAINER_UID=70

run_priv() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "error: need root or sudo to run: $*" >&2
    exit 1
  fi
}

upsert_env() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    # portable-ish in-place replace
    local tmp
    tmp="$(mktemp)"
    awk -v k="${key}" -v v="${value}" 'BEGIN{FS=OFS="="} $1==k{$0=k"="v} {print}' "${file}" >"${tmp}"
    mv "${tmp}" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${file}"
  fi
}

env_value() {
  local key="$1"
  local file="$2"
  awk -F= -v k="${key}" '$1==k{print substr($0, index($0,"=")+1); exit}' "${file}" 2>/dev/null || true
}

echo "==> Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found on PATH" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "error: docker is installed but not usable (is the daemon running? rootless user session?)" >&2
  exit 1
fi
echo "Docker OK"

echo "==> Preparing .env..."
if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${ENV_EXAMPLE}" ]]; then
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    echo "Created ${ENV_FILE} from .env.example"
  else
    touch "${ENV_FILE}"
    echo "Created empty ${ENV_FILE}"
  fi
fi

upsert_env "LINKWARDEN_DATA_ROOT" "${LINKWARDEN_DATA_ROOT}" "${ENV_FILE}"

for key in NEXTAUTH_SECRET MEILI_MASTER_KEY POSTGRES_PASSWORD; do
  current="$(env_value "${key}" "${ENV_FILE}")"
  if [[ -z "${current}" ]]; then
    generated="$(openssl rand -hex 32)"
    upsert_env "${key}" "${generated}" "${ENV_FILE}"
    echo "Generated ${key}"
  fi
done

if [[ -z "$(env_value NEXTAUTH_URL "${ENV_FILE}")" ]]; then
  upsert_env "NEXTAUTH_URL" "http://localhost:3000/api/v1/auth" "${ENV_FILE}"
fi

echo "==> Creating data directories under ${LINKWARDEN_DATA_ROOT}..."
run_priv mkdir -p "${POSTGRES_DIR}" "${MEILI_DIR}" "${LINKWARDEN_DIR}"

if [[ "$(id -u)" -ne 0 ]]; then
  run_priv chown "$(id -u):$(id -g)" "${MEILI_DIR}" "${LINKWARDEN_DIR}"
fi

# DHI Postgres runs as UID/GID 70 inside the container.
# Rootless Docker remaps via /etc/subuid (container 1 -> SUBUID, so 70 -> SUBUID+69).
host_pg_uid="${PG_CONTAINER_UID}"
host_pg_gid="${PG_CONTAINER_UID}"

if [[ "$(id -u)" -ne 0 ]]; then
  subuid_start="$(awk -F: -v u="$(id -un)" '$1 == u { print $2; exit }' /etc/subuid 2>/dev/null || true)"
  subgid_start="$(awk -F: -v u="$(id -un)" '$1 == u { print $2; exit }' /etc/subgid 2>/dev/null || true)"
  if [[ -n "${subuid_start}" && -n "${subgid_start}" ]]; then
    host_pg_uid=$((subuid_start + PG_CONTAINER_UID - 1))
    host_pg_gid=$((subgid_start + PG_CONTAINER_UID - 1))
    echo "Rootless userns: container ${PG_CONTAINER_UID} -> host ${host_pg_uid}:${host_pg_gid}"
  else
    echo "No subuid map for $(id -un); using host UID/GID ${PG_CONTAINER_UID}"
  fi
fi

echo "Setting postgres data ownership to ${host_pg_uid}:${host_pg_gid}..."
run_priv chown -R "${host_pg_uid}:${host_pg_gid}" "${POSTGRES_DIR}"
run_priv chmod 700 "${POSTGRES_DIR}"

echo "==> Checking DHI registry auth (${DHI_IMAGE})..."
if docker manifest inspect "${DHI_IMAGE}" >/dev/null 2>&1 || docker pull "${DHI_IMAGE}" >/dev/null 2>&1; then
  echo "DHI auth OK"
else
  echo "error: cannot access ${DHI_IMAGE}." >&2
  echo "Log in first (credentials are not stored in this repo):" >&2
  echo "  docker login dhi.io" >&2
  exit 1
fi

echo
echo "Host prep complete."
echo "  LINKWARDEN_DATA_ROOT=${LINKWARDEN_DATA_ROOT}"
echo "Next: cd \"${SCRIPT_DIR}\" && docker compose up -d"
