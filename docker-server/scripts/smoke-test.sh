#!/usr/bin/env bash
# Minimal push/pull verification against the deployed Harbor.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
set -a; source "${ROOT_DIR}/.env"; set +a

HOST="${HARBOR_HOSTNAME}"
USER="${SMOKE_USER:-admin}"
PASS="${HARBOR_ADMIN_PASSWORD}"
PROJECT="${SMOKE_PROJECT:-library}"
IMAGE_SRC="${SMOKE_IMAGE:-docker.io/library/alpine:3.20}"
IMAGE_DST="${HOST}/${PROJECT}/alpine:smoke"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
need docker
need curl

echo "==> Health"
curl -skf "${HARBOR_EXTERNAL_URL}/api/v2.0/health" | head -c 400 || true
echo

echo "==> Login"
echo "${PASS}" | docker login "${HOST}" -u "${USER}" --password-stdin

echo "==> Pull source ${IMAGE_SRC}"
docker pull "${IMAGE_SRC}"

echo "==> Tag/push ${IMAGE_DST}"
docker tag "${IMAGE_SRC}" "${IMAGE_DST}"
docker push "${IMAGE_DST}"

echo "==> Remove local and re-pull"
docker rmi "${IMAGE_DST}" || true
docker pull "${IMAGE_DST}"

echo "OK: smoke test passed for ${IMAGE_DST}"
echo "Optional: verify Garage objects with aws --endpoint-url ${GARAGE_S3_ENDPOINT} s3 ls s3://${GARAGE_BUCKET}/"
