#!/usr/bin/env bash
# Create Harbor bucket + access key in a single-node Garage.
# Idempotent where possible. Requires root or garage CLI access to config/meta.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: missing ${ENV_FILE}. Copy .env.example to .env and edit first." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

GARAGE_BIN_PATH="${GARAGE_BIN_PATH:-/usr/local/bin/garage}"
GARAGE_CONFIG_PATH="${GARAGE_CONFIG_PATH:-/etc/garage.toml}"
GARAGE_BUCKET="${GARAGE_BUCKET:-harbor-images}"
GARAGE_KEY_NAME="${GARAGE_KEY_NAME:-harbor-registry}"

run_garage() {
  "${GARAGE_BIN_PATH}" -c "${GARAGE_CONFIG_PATH}" "$@"
}

echo "==> Ensuring Garage is running"
systemctl is-active --quiet garage.service || systemctl start garage.service
sleep 1
run_garage status

if ! run_garage bucket info "${GARAGE_BUCKET}" >/dev/null 2>&1; then
  echo "==> Creating bucket ${GARAGE_BUCKET}"
  run_garage bucket create "${GARAGE_BUCKET}"
else
  echo "==> Bucket ${GARAGE_BUCKET} already exists"
fi

# Create key if access key not already in .env
if [[ -z "${GARAGE_ACCESS_KEY:-}" || -z "${GARAGE_SECRET_KEY:-}" ]]; then
  echo "==> Creating access key ${GARAGE_KEY_NAME}"
  # garage key create prints Key ID and Secret key
  OUT="$(run_garage key create "${GARAGE_KEY_NAME}" 2>&1 || true)"
  if echo "${OUT}" | grep -q "already exists\|Key name already exists\|already exists"; then
    echo "==> Key name exists; creating a new unique key name"
    GARAGE_KEY_NAME="${GARAGE_KEY_NAME}-$(date +%s)"
    OUT="$(run_garage key create "${GARAGE_KEY_NAME}")"
  fi
  echo "${OUT}"
  ACCESS="$(echo "${OUT}" | awk -F': ' '/Key ID:/ {print $2}' | tr -d '[:space:]')"
  SECRET="$(echo "${OUT}" | awk -F': ' '/Secret key:/ {print $2}' | tr -d '[:space:]')"
  if [[ -z "${ACCESS}" || -z "${SECRET}" ]]; then
    echo "ERROR: failed to parse Garage key output:" >&2
    echo "${OUT}" >&2
    exit 1
  fi
  # Upsert into .env
  grep -q '^GARAGE_ACCESS_KEY=' "${ENV_FILE}" && sed -i "s|^GARAGE_ACCESS_KEY=.*|GARAGE_ACCESS_KEY=${ACCESS}|" "${ENV_FILE}" || echo "GARAGE_ACCESS_KEY=${ACCESS}" >> "${ENV_FILE}"
  grep -q '^GARAGE_SECRET_KEY=' "${ENV_FILE}" && sed -i "s|^GARAGE_SECRET_KEY=.*|GARAGE_SECRET_KEY=${SECRET}|" "${ENV_FILE}" || echo "GARAGE_SECRET_KEY=${SECRET}" >> "${ENV_FILE}"
  grep -q '^GARAGE_KEY_NAME=' "${ENV_FILE}" && sed -i "s|^GARAGE_KEY_NAME=.*|GARAGE_KEY_NAME=${GARAGE_KEY_NAME}|" "${ENV_FILE}" || echo "GARAGE_KEY_NAME=${GARAGE_KEY_NAME}" >> "${ENV_FILE}"
  GARAGE_ACCESS_KEY="${ACCESS}"
  GARAGE_SECRET_KEY="${SECRET}"
  echo "==> Wrote GARAGE_ACCESS_KEY / GARAGE_SECRET_KEY to ${ENV_FILE}"
else
  echo "==> Using existing GARAGE_ACCESS_KEY from .env"
fi

echo "==> Allowing key on bucket (read/write/owner)"
# Allow by key name if we have it; otherwise by key id
if [[ -n "${GARAGE_KEY_NAME:-}" ]]; then
  run_garage bucket allow --read --write --owner "${GARAGE_BUCKET}" --key "${GARAGE_KEY_NAME}" || \
    run_garage bucket allow --read --write --owner "${GARAGE_BUCKET}" --key "${GARAGE_ACCESS_KEY}"
else
  run_garage bucket allow --read --write --owner "${GARAGE_BUCKET}" --key "${GARAGE_ACCESS_KEY}"
fi

run_garage bucket info "${GARAGE_BUCKET}"

if [[ -n "${SUDO_USER:-}" && -f "${ENV_FILE}" ]]; then
  chown "${SUDO_USER}:${SUDO_USER}" "${ENV_FILE}" || true
fi

echo "OK: Garage bucket ready for Harbor."
echo "    Endpoint (from Docker): http://host.docker.internal:3900"
echo "    Region: garage"
echo "    Bucket: ${GARAGE_BUCKET}"
