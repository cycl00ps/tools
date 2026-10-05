#!/usr/bin/env bash
# End-to-end deploy for a fresh host. Safe to re-run (mostly idempotent).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 1; }
}

harbor_compose() {
  local files=(-f harbor/docker-compose.yml)
  if [[ "${NGINX_ENABLE_HTTPS:-true}" == "true" ]]; then
    files+=(-f harbor/docker-compose.https.yml)
  fi
  docker compose "${files[@]}" --env-file harbor/.env "$@"
}

echo "==> Checking prerequisites"
need curl
need docker
docker compose version >/dev/null
need python3

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run: cp .env.example .env && edit it" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

if [[ -z "${HARBOR_HOSTNAME:-}" || "${HARBOR_HOSTNAME}" == "registry.example.local" ]]; then
  echo "WARN: HARBOR_HOSTNAME still looks like the example value." >&2
fi

echo "==> [1/5] Install Garage binary + systemd"
sudo ./garage/install.sh

echo "==> [2/5] Bootstrap Garage bucket/key"
sudo ./garage/bootstrap.sh

# Re-load .env after bootstrap may have written keys
set -a; source .env; set +a

echo "==> [3/5] docker login dhi.io (interactive if not already logged in)"
if ! docker pull dhi.io/harbor-core:2.15.2-debian13 >/dev/null 2>&1; then
  echo "Login required for dhi.io (Docker Hub credentials)."
  docker login dhi.io
fi

echo "==> [4/5] Prepare Harbor configs/secrets"
./harbor/prepare.sh

# Re-load generated compose env (HARBOR_DATA_DIR, NGINX_ENABLE_HTTPS, …)
set -a; source harbor/.env; set +a

echo "==> [5/5] Start Harbor Compose stack"
harbor_compose pull
harbor_compose up -d

echo
echo "==> Waiting for core API..."
for i in $(seq 1 60); do
  if curl -skf "${HARBOR_EXTERNAL_URL}/api/v2.0/health" >/dev/null 2>&1; then
    echo "OK: Harbor health endpoint responded"
    break
  fi
  sleep 5
  if [[ "$i" -eq 60 ]]; then
    echo "WARN: health check timed out; inspect: harbor compose logs core" >&2
  fi
done

echo
echo "Deploy complete."
echo "  Portal:  ${HARBOR_EXTERNAL_URL}"
echo "  User:    admin"
echo "  Pass:    (HARBOR_ADMIN_PASSWORD from .env)"
echo "  HTTPS:   NGINX_ENABLE_HTTPS=${NGINX_ENABLE_HTTPS:-true}"
echo "  Smoke:   ./scripts/smoke-test.sh"
echo
if [[ "${NGINX_ENABLE_HTTPS:-true}" != "true" ]]; then
  echo "HTTP-only nginx: point your TLS terminator (e.g. Caddy) at"
  echo "  http://${PROXY_HTTP_BIND:-127.0.0.1}:${HTTP_PORT:-80}"
  echo "and set HARBOR_EXTERNAL_URL to the public https:// URL."
elif [[ "${HARBOR_EXTERNAL_URL}" == http://* ]]; then
  _reg="${HARBOR_EXTERNAL_URL#http://}"
  _reg="${_reg%%/*}"
  echo "HTTP lab mode: add \"${_reg}\" to Docker insecure-registries, then restart Docker."
  echo "  Rootless: ~/.config/docker/daemon.json → systemctl --user restart docker"
else
  echo "If using a self-signed cert, trust harbor/secrets/tls/tls.crt on clients,"
  echo "or temporarily configure the Docker daemon insecure-registries for lab use."
fi
