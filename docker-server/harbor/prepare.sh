#!/usr/bin/env bash
# Render Harbor configs/secrets from .env into harbor/generated (deterministic, re-runnable).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_DIR="${ROOT_DIR}/harbor"
GEN="${HARBOR_DIR}/generated"
SECRETS="${HARBOR_DIR}/secrets"
ENV_FILE="${ROOT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} missing. Copy .env.example -> .env and fill values." >&2
  exit 1
fi

# shellcheck disable=SC1090,SC1091
set -a
source "${ROOT_DIR}/versions.env"
source "${ENV_FILE}"
set +a

: "${HARBOR_HOSTNAME:?set HARBOR_HOSTNAME in .env}"
: "${HARBOR_EXTERNAL_URL:?set HARBOR_EXTERNAL_URL in .env}"
: "${HARBOR_ADMIN_PASSWORD:?set HARBOR_ADMIN_PASSWORD in .env}"
: "${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}"
: "${GARAGE_ACCESS_KEY:?set GARAGE_ACCESS_KEY (run garage/bootstrap.sh first)}"
: "${GARAGE_SECRET_KEY:?set GARAGE_SECRET_KEY}"
: "${GARAGE_BUCKET:?set GARAGE_BUCKET}"
: "${GARAGE_S3_ENDPOINT:?set GARAGE_S3_ENDPOINT (e.g. http://host.docker.internal:3900)}"

rand_alnum() {
  local n="${1:-16}"
  python3 -c 'import secrets,string,sys; n=int(sys.argv[1]); a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(n)))' "${n}"
}
rand16() { rand_alnum 16; }
rand32() { rand_alnum 32; }

upsert_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    # portable-ish in-place replace
    python3 - "$ENV_FILE" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
out, found = [], False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={val}")
        found = True
    else:
        out.append(line)
if not found:
    out.append(f"{key}={val}")
open(path, "w").write("\n".join(out) + "\n")
PY
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

ensure_secret() {
  local key="$1"
  local cur="${!key:-}"
  if [[ -z "${cur}" ]]; then
    cur="$(rand16)"
    upsert_env "${key}" "${cur}"
    printf -v "${key}" '%s' "${cur}"
    echo "==> Generated ${key}"
  fi
}

ensure_secret CORE_SECRET
ensure_secret JOBSERVICE_SECRET
# Harbor 2.15 requires CSRF_KEY length == 32
if [[ -z "${CSRF_KEY:-}" || ${#CSRF_KEY} -ne 32 ]]; then
  CSRF_KEY="$(rand32)"
  upsert_env CSRF_KEY "${CSRF_KEY}"
  echo "==> Generated CSRF_KEY (32 chars)"
fi
ensure_secret REGISTRY_CREDENTIAL_PASSWORD
REGISTRY_CREDENTIAL_USERNAME="${REGISTRY_CREDENTIAL_USERNAME:-harbor_registry_user}"
upsert_env REGISTRY_CREDENTIAL_USERNAME "${REGISTRY_CREDENTIAL_USERNAME}"

mkdir -p "${GEN}/nginx" "${GEN}/registry" "${GEN}/registryctl" "${GEN}/jobservice" "${GEN}/core" "${GEN}/portal" \
  "${SECRETS}/core" "${SECRETS}/registry" "${SECRETS}/tls" \
  "${ROOT_DIR}/data/harbor/database" "${ROOT_DIR}/data/harbor/redis" \
  "${ROOT_DIR}/data/harbor/job_logs" "${ROOT_DIR}/data/harbor/trivy" "${ROOT_DIR}/data/harbor/core"

# --- TLS certs (self-signed if missing) ---
TLS_CRT="${SECRETS}/tls/tls.crt"
TLS_KEY="${SECRETS}/tls/tls.key"
if [[ ! -f "${TLS_CRT}" || ! -f "${TLS_KEY}" ]]; then
  echo "==> Generating self-signed TLS cert for ${HARBOR_HOSTNAME}"
  if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
      -keyout "${TLS_KEY}" -out "${TLS_CRT}" \
      -subj "/CN=${HARBOR_HOSTNAME}" \
      -addext "subjectAltName=DNS:${HARBOR_HOSTNAME},DNS:localhost,IP:127.0.0.1"
  else
    echo "==> openssl not on host; using docker alpine/openssl"
    docker run --rm -v "${SECRETS}/tls:/out" alpine/openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
      -keyout /out/tls.key -out /out/tls.crt \
      -subj "/CN=${HARBOR_HOSTNAME}" \
      -addext "subjectAltName=DNS:${HARBOR_HOSTNAME},DNS:localhost,IP:127.0.0.1"
  fi
  chmod 0644 "${TLS_CRT}"
  chmod 0640 "${TLS_KEY}"
fi

# --- Core token signing key + registry root cert ---
PRIV="${SECRETS}/core/private_key.pem"
ROOTCRT="${SECRETS}/registry/root.crt"
if [[ ! -f "${PRIV}" || ! -f "${ROOTCRT}" ]]; then
  echo "==> Generating Harbor token signing keypair (traditional RSA PEM)"
  # Harbor token service requires PKCS#1 "BEGIN RSA PRIVATE KEY" (-traditional),
  # not PKCS#8 "BEGIN PRIVATE KEY".
  if command -v openssl >/dev/null 2>&1; then
    openssl genrsa -traditional -out "${PRIV}" 4096
    openssl req -new -x509 -key "${PRIV}" -out "${ROOTCRT}" -days 3650 -subj "/"
  else
    docker run --rm -v "${SECRETS}:/s" alpine/openssl genrsa -traditional -out /s/core/private_key.pem 4096
    docker run --rm -v "${SECRETS}:/s" alpine/openssl req -new -x509 -key /s/core/private_key.pem -out /s/registry/root.crt -days 3650 -subj "/"
  fi
  chmod 0640 "${PRIV}" "${ROOTCRT}"
fi

# secretkey file (exactly 16 chars) for /etc/core/key
SECRETKEY_FILE="${SECRETS}/core/secretkey"
if [[ ! -f "${SECRETKEY_FILE}" ]]; then
  ensure_secret HARBOR_SECRET_KEY
  # force length 16
  if [[ ${#HARBOR_SECRET_KEY} -ne 16 ]]; then
    HARBOR_SECRET_KEY="$(rand16)"
    upsert_env HARBOR_SECRET_KEY "${HARBOR_SECRET_KEY}"
  fi
  printf '%s' "${HARBOR_SECRET_KEY}" > "${SECRETKEY_FILE}"
  chmod 0640 "${SECRETKEY_FILE}"
fi

# --- htpasswd for registry ---
PASSWD_FILE="${GEN}/registry/passwd"
echo "==> Writing registry htpasswd"
if command -v htpasswd >/dev/null 2>&1; then
  htpasswd -nbB "${REGISTRY_CREDENTIAL_USERNAME}" "${REGISTRY_CREDENTIAL_PASSWORD}" > "${PASSWD_FILE}"
else
  docker run --rm --entrypoint htpasswd httpd:2.4-alpine \
    -nbB "${REGISTRY_CREDENTIAL_USERNAME}" "${REGISTRY_CREDENTIAL_PASSWORD}" > "${PASSWD_FILE}"
fi

# --- Render configs ---
sed \
  -e "s|__GARAGE_ACCESS_KEY__|${GARAGE_ACCESS_KEY}|g" \
  -e "s|__GARAGE_SECRET_KEY__|${GARAGE_SECRET_KEY}|g" \
  -e "s|__GARAGE_S3_ENDPOINT__|${GARAGE_S3_ENDPOINT}|g" \
  -e "s|__GARAGE_BUCKET__|${GARAGE_BUCKET}|g" \
  "${HARBOR_DIR}/templates/registry/config.yml.tmpl" > "${GEN}/registry/config.yml"

cp "${HARBOR_DIR}/templates/registryctl/config.yml" "${GEN}/registryctl/config.yml"
cp "${HARBOR_DIR}/templates/jobservice/config.yml.tmpl" "${GEN}/jobservice/config.yml"
cp "${HARBOR_DIR}/templates/core/app.conf" "${GEN}/core/app.conf"
cp "${HARBOR_DIR}/templates/portal/nginx.conf" "${GEN}/portal/nginx.conf"
cp "${HARBOR_DIR}/templates/nginx/nginx.conf.tmpl" "${GEN}/nginx/nginx.conf"

# DHI images run as uid 65532 (nonroot). Make data dirs world-writable or owned by 65532.
echo "==> Fixing data directory permissions for nonroot (uid 65532)"
chmod -R a+rwX \
  "${ROOT_DIR}/data/harbor/database" \
  "${ROOT_DIR}/data/harbor/redis" \
  "${ROOT_DIR}/data/harbor/job_logs" \
  "${ROOT_DIR}/data/harbor/trivy" \
  "${ROOT_DIR}/data/harbor/core" 2>/dev/null || true
# secrets readable by nonroot
chmod -R a+rX "${SECRETS}" "${GEN}"
chmod 0640 "${TLS_KEY}" "${PRIV}" "${SECRETKEY_FILE}" 2>/dev/null || true
# nonroot needs to read key/certs — grant o+r for container uid when not matching host
chmod a+r "${TLS_KEY}" "${PRIV}" "${SECRETKEY_FILE}" "${ROOTCRT}" "${TLS_CRT}"

# Write compose env overlay used by docker compose
cat > "${HARBOR_DIR}/.env" <<EOF
# Generated by harbor/prepare.sh — do not edit by hand; edit ../.env then re-run prepare.
COMPOSE_PROJECT_NAME=harbor
HARBOR_HOSTNAME=${HARBOR_HOSTNAME}
HARBOR_EXTERNAL_URL=${HARBOR_EXTERNAL_URL}
HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
CORE_SECRET=${CORE_SECRET}
JOBSERVICE_SECRET=${JOBSERVICE_SECRET}
CSRF_KEY=${CSRF_KEY}
REGISTRY_CREDENTIAL_USERNAME=${REGISTRY_CREDENTIAL_USERNAME}
REGISTRY_CREDENTIAL_PASSWORD=${REGISTRY_CREDENTIAL_PASSWORD}
HARBOR_CORE_IMAGE=${HARBOR_CORE_IMAGE}
HARBOR_PORTAL_IMAGE=${HARBOR_PORTAL_IMAGE}
HARBOR_JOBSERVICE_IMAGE=${HARBOR_JOBSERVICE_IMAGE}
HARBOR_REGISTRY_IMAGE=${HARBOR_REGISTRY_IMAGE}
HARBOR_REGISTRYCTL_IMAGE=${HARBOR_REGISTRYCTL_IMAGE}
HARBOR_TRIVY_IMAGE=${HARBOR_TRIVY_IMAGE}
HARBOR_EXPORTER_IMAGE=${HARBOR_EXPORTER_IMAGE}
HARBOR_DB_IMAGE=${HARBOR_DB_IMAGE}
HARBOR_REDIS_IMAGE=${HARBOR_REDIS_IMAGE}
NGINX_IMAGE=${NGINX_IMAGE}
HTTP_PORT=${HTTP_PORT:-80}
HTTPS_PORT=${HTTPS_PORT:-443}
EOF

echo "OK: Harbor configs rendered under ${GEN}"
echo "    Next: docker login dhi.io && docker compose -f harbor/docker-compose.yml --env-file harbor/.env up -d"
