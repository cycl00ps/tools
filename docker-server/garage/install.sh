#!/usr/bin/env bash
# Install Garage as a host binary + systemd unit (single-node).
# Idempotent. Requires root (or sudo).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/versions.env"

ENV_FILE="${ROOT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
fi

GARAGE_META_DIR="${GARAGE_META_DIR:-/var/lib/garage/meta}"
GARAGE_DATA_DIR="${GARAGE_DATA_DIR:-/var/lib/garage/data}"
GARAGE_RPC_PUBLIC_ADDR="${GARAGE_RPC_PUBLIC_ADDR:-127.0.0.1:3901}"
GARAGE_BIN_PATH="${GARAGE_BIN_PATH:-/usr/local/bin/garage}"
GARAGE_CONFIG_PATH="${GARAGE_CONFIG_PATH:-/etc/garage.toml}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: garage/install.sh must run as root (use sudo)." >&2
  exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64|amd64) GARAGE_ARCH="x86_64-unknown-linux-musl" ;;
  aarch64|arm64) GARAGE_ARCH="aarch64-unknown-linux-musl" ;;
  *)
    echo "ERROR: unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

DOWNLOAD_URL="https://garagehq.deuxfleurs.fr/_releases/${GARAGE_VERSION}/${GARAGE_ARCH}/garage"
echo "==> Downloading Garage ${GARAGE_VERSION} (${GARAGE_ARCH})"
TMP="$(mktemp)"
curl -fsSL "${DOWNLOAD_URL}" -o "${TMP}"
install -m 0755 "${TMP}" "${GARAGE_BIN_PATH}"
rm -f "${TMP}"
"${GARAGE_BIN_PATH}" --version || true

if ! id -u garage >/dev/null 2>&1; then
  useradd --system --home /var/lib/garage --shell /usr/sbin/nologin garage
fi

mkdir -p "${GARAGE_META_DIR}" "${GARAGE_DATA_DIR}"
chown -R garage:garage /var/lib/garage

if [[ -z "${GARAGE_RPC_SECRET:-}" ]]; then
  GARAGE_RPC_SECRET="$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(32))')"
  echo "GARAGE_RPC_SECRET=${GARAGE_RPC_SECRET}" >> "${ENV_FILE}"
  echo "==> Generated GARAGE_RPC_SECRET and appended to ${ENV_FILE}"
fi
if [[ -z "${GARAGE_ADMIN_TOKEN:-}" ]]; then
  GARAGE_ADMIN_TOKEN="$(openssl rand -base64 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  echo "GARAGE_ADMIN_TOKEN=${GARAGE_ADMIN_TOKEN}" >> "${ENV_FILE}"
  echo "==> Generated GARAGE_ADMIN_TOKEN and appended to ${ENV_FILE}"
fi

sed \
  -e "s|{{GARAGE_META_DIR}}|${GARAGE_META_DIR}|g" \
  -e "s|{{GARAGE_DATA_DIR}}|${GARAGE_DATA_DIR}|g" \
  -e "s|{{GARAGE_RPC_PUBLIC_ADDR}}|${GARAGE_RPC_PUBLIC_ADDR}|g" \
  -e "s|{{GARAGE_RPC_SECRET}}|${GARAGE_RPC_SECRET}|g" \
  -e "s|{{GARAGE_ADMIN_TOKEN}}|${GARAGE_ADMIN_TOKEN}|g" \
  "${ROOT_DIR}/garage/garage.toml.example" > "${GARAGE_CONFIG_PATH}"
chmod 0640 "${GARAGE_CONFIG_PATH}"
chown root:garage "${GARAGE_CONFIG_PATH}"

install -m 0644 "${ROOT_DIR}/garage/garage.service" /etc/systemd/system/garage.service
systemctl daemon-reload
systemctl enable garage.service
systemctl restart garage.service

if [[ -n "${SUDO_USER:-}" && -f "${ENV_FILE}" ]]; then
  chown "${SUDO_USER}:${SUDO_USER}" "${ENV_FILE}" || true
fi

echo "==> Waiting for Garage to become ready..."
for _ in $(seq 1 30); do
  if "${GARAGE_BIN_PATH}" -c "${GARAGE_CONFIG_PATH}" status >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "==> Garage status:"
"${GARAGE_BIN_PATH}" -c "${GARAGE_CONFIG_PATH}" status || true
echo "OK: Garage installed. Next: sudo ./garage/bootstrap.sh"
