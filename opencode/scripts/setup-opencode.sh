#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# OpenCode bootstrap — idempotent installer for Linux (host / VM / container).
# See ../runbook/README.md for full documentation.
#
# Usage:
#   ./scripts/setup-opencode.sh [--install-only] [--skip-install] [--with-ca FILE]
#
# Environment:
#   OPENCODE_VERSION     — pin install script version (e.g. 0.1.0)
#   OPENCODE_INSTALL_METHOD — force: auto | dnf | script | skip
#   OPENCODE_SKIP_INSTALL=1 — same as --skip-install
# -----------------------------------------------------------------------------

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ONLY=0
SKIP_INSTALL=0
CA_BUNDLE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-only) INSTALL_ONLY=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --with-ca)
      CA_BUNDLE="${2:?--with-ca requires a file path}"
      shift 2
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${OPENCODE_SKIP_INSTALL:-}" ]] && SKIP_INSTALL=1

log() { printf '[opencode-bootstrap] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

need_cmd bash
need_cmd curl

install_via_script() {
  local ver="${OPENCODE_VERSION:-}"
  if [[ -n "$ver" ]]; then
    log "Installing OpenCode via upstream install script (VERSION=$ver)..."
    curl -fsSL "https://raw.githubusercontent.com/opencode-ai/opencode/refs/heads/main/install" | VERSION="$ver" bash
  else
    log "Installing OpenCode via upstream install script (latest)..."
    curl -fsSL "https://raw.githubusercontent.com/opencode-ai/opencode/refs/heads/main/install" | bash
  fi
}

install_via_dnf() {
  if ! command -v dnf >/dev/null 2>&1; then
    return 1
  fi
  for pkg in opencode opencode-ai; do
    log "Trying dnf install -y $pkg ..."
    if dnf install -y "$pkg"; then
      log "Installed OpenCode via dnf (package: $pkg)."
      return 0
    fi
  done
  log "dnf could not install a matching package (ok if not packaged in your repos)."
  return 1
}

install_opencode() {
  local method="${OPENCODE_INSTALL_METHOD:-auto}"
  case "$method" in
    skip) log "Skipping install (OPENCODE_INSTALL_METHOD=skip)."; return 0 ;;
    dnf)
      install_via_dnf || die "dnf install failed or package not found. Try OPENCODE_INSTALL_METHOD=script or install manually."
      ;;
    script)
      install_via_script
      ;;
    auto)
      if install_via_dnf; then
        return 0
      fi
      log "No dnf package matched; falling back to official install script."
      install_via_script
      ;;
    *)
      die "Unknown OPENCODE_INSTALL_METHOD=$method (use auto|dnf|script|skip)"
      ;;
  esac
}

trust_internal_ca() {
  [[ -z "$CA_BUNDLE" ]] && return 0
  [[ -f "$CA_BUNDLE" ]] || die "CA bundle not found: $CA_BUNDLE"

  if [[ -d /etc/pki/ca-trust/source/anchors ]] && command -v update-ca-trust >/dev/null 2>&1; then
    local dest="/etc/pki/ca-trust/source/anchors/opencode-internal-ca.pem"
    log "Installing CA into system trust: $dest"
    cp -f "$CA_BUNDLE" "$dest"
    update-ca-trust extract
    log "System CA trust updated."
  elif [[ -d /usr/local/share/ca-certificates ]] && command -v update-ca-certificates >/dev/null 2>&1; then
    log "Installing CA into /usr/local/share/ca-certificates/"
    cp -f "$CA_BUNDLE" "/usr/local/share/ca-certificates/opencode-internal-ca.crt"
    update-ca-certificates
  else
    log "WARN: Could not install CA system-wide. Export NODE_EXTRA_CA_CERTS=$CA_BUNDLE for Node-based tooling, or trust manually."
  fi
}

render_config() {
  local tmpl="$ROOT/config/opencode.jsonc.template"
  local out_global="$HOME/.config/opencode/opencode.jsonc"
  local out_project="$ROOT/opencode.jsonc"

  if [[ ! -f "$tmpl" ]]; then
    log "WARN: Template missing: $tmpl"
    return 0
  fi

  if [[ "${RENDER_GLOBAL_CONFIG:-0}" == "1" ]]; then
    mkdir -p "$(dirname "$out_global")"
    if [[ ! -f "$out_global" ]] || [[ "${OVERWRITE_CONFIG:-0}" == "1" ]]; then
      cp -f "$tmpl" "$out_global"
      log "Wrote global config: $out_global"
    else
      log "Skipping existing global config (set OVERWRITE_CONFIG=1 to replace): $out_global"
    fi
  fi

  if [[ ! -f "$out_project" ]] || [[ "${OVERWRITE_CONFIG:-0}" == "1" ]]; then
    cp -f "$tmpl" "$out_project"
    log "Wrote project config: $out_project"
  else
    log "Skipping existing project config (set OVERWRITE_CONFIG=1 to replace): $out_project"
  fi
}

link_env_example() {
  local ex="$ROOT/config/env.example"
  local envf="$ROOT/.env"
  if [[ -f "$ex" ]] && [[ ! -f "$envf" ]]; then
    cp "$ex" "$envf"
    log "Created $envf from env.example — edit secrets before use."
  elif [[ -f "$envf" ]]; then
    log ".env already exists; not overwriting."
  fi
}

# -----------------------------------------------------------------------------
main() {
  log "ROOT=$ROOT"

  if [[ "$SKIP_INSTALL" -eq 0 ]]; then
    install_opencode
  else
    log "Skipping OpenCode install (--skip-install / OPENCODE_SKIP_INSTALL)."
  fi

  trust_internal_ca
  render_config
  link_env_example

  mkdir -p "$ROOT/.opencode/plugins"

  # Optional: point OpenCode at this project config (uncomment in your shell profile if desired)
  cat >"$ROOT/config/shell-snippet.sh" <<'SNIP'
# Source or copy into ~/.bashrc / ~/.zshrc if you want explicit config paths:
# export OPENCODE_CONFIG="/ABS/PATH/TO/opencode/opencode.jsonc"
# export OPENCODE_CONFIG_DIR="/ABS/PATH/TO/opencode/.opencode"
SNIP
  sed -i "s|/ABS/PATH/TO/opencode|$ROOT|g" "$ROOT/config/shell-snippet.sh"

  if [[ "$INSTALL_ONLY" -eq 1 ]]; then
    log "Done (--install-only)."
    exit 0
  fi

  if command -v opencode >/dev/null 2>&1; then
    opencode --version || true
  else
    log "WARN: opencode not found in PATH after install. Open a new shell or add its install dir to PATH."
  fi

  log "Bootstrap finished. Next: edit config/opencode.jsonc.template values → opencode.jsonc, fill .env, run scripts/validate-opencode.sh"
}

main "$@"
