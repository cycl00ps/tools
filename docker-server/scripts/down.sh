#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f harbor/.env ]]; then
  # shellcheck disable=SC1091
  set -a; source harbor/.env; set +a
fi

files=(-f harbor/docker-compose.yml)
if [[ "${NGINX_ENABLE_HTTPS:-true}" == "true" ]]; then
  files+=(-f harbor/docker-compose.https.yml)
fi

docker compose "${files[@]}" --env-file harbor/.env down
echo "Harbor stack stopped. Garage systemd unit left running (sudo systemctl stop garage to stop it)."
