#!/usr/bin/env bash
# End-to-end deploy for a fresh host. Safe to re-run (mostly idempotent).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1" >&2; exit 1; }
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

echo "==> [5/5] Start Harbor Compose stack"
docker compose -f harbor/docker-compose.yml --env-file harbor/.env pull
docker compose -f harbor/docker-compose.yml --env-file harbor/.env up -d

echo
echo "==> Waiting for core API..."
for i in $(seq 1 60); do
  if curl -skf "${HARBOR_EXTERNAL_URL}/api/v2.0/health" >/dev/null 2>&1; then
    echo "OK: Harbor health endpoint responded"
    break
  fi
  sleep 5
  if [[ "$i" -eq 60 ]]; then
    echo "WARN: health check timed out; inspect: docker compose -f harbor/docker-compose.yml logs core" >&2
  fi
done

echo
echo "Deploy complete."
echo "  Portal:  ${HARBOR_EXTERNAL_URL}"
echo "  User:    admin"
echo "  Pass:    (HARBOR_ADMIN_PASSWORD from .env)"
echo "  Smoke:   ./scripts/smoke-test.sh"
echo
echo "If using a self-signed cert, trust harbor/secrets/tls/tls.crt on clients,"
echo "or temporarily configure the Docker daemon insecure-registries for lab use."
