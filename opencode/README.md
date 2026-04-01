# OpenCode local bootstrap

Bootstrap bundle to install [OpenCode](https://opencode.ai) and configure **multiple local OpenAI-compatible** endpoints (HTTPS, per-endpoint API keys), with room for **plugins** later.

**Start here:** [runbook/README.md](runbook/README.md)

Quick start:

```bash
chmod +x scripts/setup-opencode.sh scripts/validate-opencode.sh
./scripts/setup-opencode.sh
# Edit opencode.jsonc and .env, then:
./scripts/validate-opencode.sh
```
