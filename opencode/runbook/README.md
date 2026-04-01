# OpenCode bootstrap runbook

This folder documents how to install and configure [OpenCode](https://opencode.ai) against **multiple local OpenAI-compatible** endpoints (direct or gateway), with **HTTPS + internal CA** support and a path for **future plugins**.

Repository layout:

| Path | Purpose |
|------|---------|
| [scripts/setup-opencode.sh](../scripts/setup-opencode.sh) | Idempotent installer (dnf → official install script fallback) |
| [scripts/validate-opencode.sh](../scripts/validate-opencode.sh) | Post-install checks + optional smoke test |
| [config/opencode.jsonc.template](../config/opencode.jsonc.template) | Provider/model template (JSONC) |
| [config/env.example](../config/env.example) | Environment variable contract for API keys |
| [.opencode/plugins/](../.opencode/plugins/) | Local plugin drop-in directory |

---

## Prerequisites

- **Shell:** bash
- **Network:** for first-time OpenCode install (curl)
- **Local LLM servers:** OpenAI-compatible HTTP API (typically `/v1/chat/completions`); `baseURL` usually ends with `/v1` ([custom provider docs](https://opencode.ai/docs/providers/#custom-provider))
- **Optional:** Bun (used by OpenCode to install **npm-listed** plugins)

---

## 1. Endpoint inventory

Fill this before editing config:

| Field | Example | Notes |
|-------|---------|--------|
| `provider_id` | `local-a` | Short ID; used as `provider_id/model_id` |
| `baseURL` | `https://host:8443/v1` | Must match your server’s OpenAI-compatible root |
| `model_id` | `primary-model` | Must match what the server accepts in `model` |
| API key env | `LOCAL_A_API_KEY` | Per-endpoint secret; referenced as `{env:...}` in config |
| Extra headers | — | Optional; use `options.headers` in JSONC |
| TLS | Internal CA | See [HTTPS / internal CA](#3-https--internal-ca) |

If you use a **gateway**, one `baseURL` may expose several models; set `provider_id` (e.g. `gateway`) and list each routable `model_id` under `models`.

---

## 2. Native host setup

### 2.1 Run the bootstrap script

From the repository root:

```bash
chmod +x scripts/setup-opencode.sh scripts/validate-opencode.sh
./scripts/setup-opencode.sh
```

Options:

| Flag / env | Meaning |
|------------|---------|
| `--skip-install` | Do not install OpenCode (use existing binary) |
| `OPENCODE_SKIP_INSTALL=1` | Same as above |
| `--install-only` | Install only; skip config copy (rare) |
| `--with-ca /path/to/ca.pem` | Install PEM into system trust (Fedora/RHEL or Debian-style paths) |
| `OPENCODE_VERSION=0.x.y` | Pin version for the **official install script** |
| `OPENCODE_INSTALL_METHOD=auto\|dnf\|script\|skip` | Override install strategy |
| `RENDER_GLOBAL_CONFIG=1` | Also copy template to `~/.config/opencode/opencode.jsonc` |
| `OVERWRITE_CONFIG=1` | Overwrite existing `opencode.jsonc` |

**Install behavior:** the script tries `dnf install` for packages named `opencode` or `opencode-ai`. If neither is available in your repos, it falls back to the **official** install script from the OpenCode GitHub repo ([README install section](https://github.com/opencode-ai/opencode#installation)).

### 2.2 Configure providers

1. Edit **`opencode.jsonc`** in the repo root (created from the template), or edit **`config/opencode.jsonc.template`** and re-run setup with `OVERWRITE_CONFIG=1`.
2. Set real `baseURL` values and model IDs.
3. Copy **`config/env.example`** to **`.env`** (created automatically if missing) and set `LOCAL_A_API_KEY`, `LOCAL_B_API_KEY`, etc.

OpenCode merges [several config locations](https://opencode.ai/docs/config/). Project config is discovered from the current directory **or** parent directories up to the **nearest Git root**. If your workspace is **not** a Git repository, set `OPENCODE_CONFIG` / `OPENCODE_CONFIG_DIR` explicitly (the validate script does this for this repo). You can force paths:

```bash
export OPENCODE_CONFIG="/absolute/path/to/opencode/opencode.jsonc"
export OPENCODE_CONFIG_DIR="/absolute/path/to/opencode/.opencode"
```

A generated helper snippet is in **`config/shell-snippet.sh`** after setup.

### 2.3 Optional: register credentials via TUI

You can store keys via `opencode auth login` (see [CLI](https://opencode.ai/docs/cli/)); this bootstrap prefers **env-based** keys in JSONC for automation and per-endpoint clarity.

### 2.4 Validate

```bash
./scripts/validate-opencode.sh
```

Optional end-to-end LLM call:

```bash
export OPENCODE_SMOKE_MODEL=local-a/primary-model
./scripts/validate-opencode.sh
```

---

## 3. HTTPS / internal CA

If endpoints use TLS signed by an **internal CA**:

1. **System trust (recommended for OpenCode’s Go runtime):**
   - **Fedora/RHEL:** place PEM under `/etc/pki/ca-trust/source/anchors/` and run `update-ca-trust extract`.
   - **Debian/Ubuntu:** place under `/usr/local/share/ca-certificates/` and run `update-ca-certificates`.

   Or use **`./scripts/setup-opencode.sh --with-ca /path/to/ca-bundle.pem`** (requires root for those paths).

2. **Application-level (supplement):** some stacks honor `NODE_EXTRA_CA_CERTS` for Node-based components (e.g. plugin installs). Example:

   ```bash
   export NODE_EXTRA_CA_CERTS=/path/to/internal-ca-bundle.pem
   ```

3. **Verify TLS** outside OpenCode:

   ```bash
   curl -vS "https://your-endpoint:8443/v1/models"
   ```

---

## 4. Switching: direct endpoints vs gateway

- **Direct (default template):** multiple `provider` entries (`local-a`, `local-b`), each with its own `baseURL` and `apiKey`.
- **Gateway:** add a single provider (e.g. `gateway`), set `enabled_providers` and `model` to that provider’s IDs, and comment out or remove unused direct blocks.

No script change is required—only **`opencode.jsonc`** and **`.env`**.

---

## 5. VM / microVM image

1. Base image: Fedora or Debian with `curl`, `bash`, `ca-certificates`.
2. Copy this repository into the image (or clone in cloud-init).
3. Run `./scripts/setup-opencode.sh` (optionally `--with-ca` during image build).
4. Bake **non-secret** defaults into `opencode.jsonc`; inject secrets at runtime via **environment** or a secret manager mounting `.env` or env vars.

For **immutable** images, set `OPENCODE_SKIP_INSTALL=1` if you pre-install OpenCode in the image layer.

---

## 6. Docker

Example **pattern** (adjust base image and paths):

```dockerfile
FROM fedora:42
RUN dnf install -y ca-certificates curl bash
WORKDIR /workspace
COPY . /workspace
RUN chmod +x scripts/setup-opencode.sh && ./scripts/setup-opencode.sh
# Optional: bake internal CA during build (requires root in Dockerfile)
# COPY internal-ca.pem /tmp/ca.pem
# RUN ./scripts/setup-opencode.sh --with-ca /tmp/ca.pem
ENV OPENCODE_CONFIG=/workspace/opencode.jsonc
ENV OPENCODE_CONFIG_DIR=/workspace/.opencode
```

At **runtime**, mount `.env` or pass `-e LOCAL_A_API_KEY=...` and keep `opencode.jsonc` on a volume if you customize per environment.

---

## 7. Troubleshooting

| Symptom | Checks |
|---------|--------|
| `opencode models` empty / errors | `baseURL` includes `/v1`; server reachable; TLS trust; `apiKey` correct |
| 401/403 | Wrong key; add `headers` if your gateway uses non-Bearer auth |
| TLS errors | Install CA system-wide; try `NODE_EXTRA_CA_CERTS` |
| Wrong model name | Model id in config must match server’s expected `model` string |
| Autoupdate surprises | Package-manager installs may disable autoupdate; see [config docs](https://opencode.ai/docs/config/) |

---

## 8. Plugins (later)

See [plugins/README.md](../plugins/README.md). Add npm package names to the `plugin` array in `opencode.jsonc`, or drop local plugins under `.opencode/plugins/`.

---

## References

- [OpenCode configuration](https://opencode.ai/docs/config/)
- [Providers / custom OpenAI-compatible](https://opencode.ai/docs/providers/)
- [Plugins](https://opencode.ai/docs/plugins/)
- [CLI](https://opencode.ai/docs/cli/)
