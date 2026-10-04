#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker compose -f "${ROOT_DIR}/harbor/docker-compose.yml" --env-file "${ROOT_DIR}/harbor/.env" down
echo "Harbor stack stopped. Garage systemd unit left running (sudo systemctl stop garage to stop it)."
