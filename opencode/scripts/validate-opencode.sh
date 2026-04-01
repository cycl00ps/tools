#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Post-setup validation for OpenCode + local providers.
# Run from project root or any directory with opencode.json / env loaded.
#
# Usage:
#   ./scripts/validate-opencode.sh
#   OPENCODE_SMOKE_MODEL=local-a/primary-model ./scripts/validate-opencode.sh
#
# Loads .env from repo root if present.
# -----------------------------------------------------------------------------

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

log() { printf '[validate-opencode] %s\n' "$*"; }
warn() { printf '[validate-opencode] WARN: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

export OPENCODE_CONFIG="${OPENCODE_CONFIG:-$ROOT/opencode.jsonc}"
export OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$ROOT/.opencode}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1 (run scripts/setup-opencode.sh)"
}

need_cmd opencode

log "OPENCODE_CONFIG=$OPENCODE_CONFIG"
log "OPENCODE_CONFIG_DIR=$OPENCODE_CONFIG_DIR"

if [[ ! -f "$OPENCODE_CONFIG" ]]; then
  warn "Config file not found: $OPENCODE_CONFIG"
  warn "Copy config/opencode.jsonc.template to opencode.jsonc or set OPENCODE_CONFIG."
fi

log "Checking version..."
opencode --version

log "Listing models (configured providers)..."
opencode models || warn "opencode models reported an error — check provider baseURL, TLS, and API keys."

if [[ -n "${OPENCODE_SMOKE_MODEL:-}" ]]; then
  log "Smoke test: opencode run (model=$OPENCODE_SMOKE_MODEL)..."
  opencode run -m "$OPENCODE_SMOKE_MODEL" -- "Reply with exactly: OK"
else
  log "Skipping LLM smoke test (set OPENCODE_SMOKE_MODEL=provider/model to enable)."
fi

log "Validation finished."
