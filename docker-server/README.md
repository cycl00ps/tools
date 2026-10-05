# Harbor (DHI) + Garage — private container registry

On-prem Docker/OCI registry using:

| Layer | Component |
|-------|-----------|
| Registry UI / API / scanning | **Harbor 2.15** as **Docker Hardened Images** (`dhi.io/harbor-*`) |
| Orchestration | **Docker Compose** (this repo) |
| Object storage | **Garage** binary, single-node, systemd |

No Kubernetes. No MinIO. Image blobs live in Garage (S3); Harbor DB/Redis/job logs use local bind mounts under `data/harbor` (or `HARBOR_DATA_DIR`).

## Quick deploy (human or agent)

```bash
cp .env.example .env
# Edit HARBOR_HOSTNAME, HARBOR_EXTERNAL_URL, HARBOR_ADMIN_PASSWORD,
# POSTGRES_PASSWORD, GARAGE_S3_ENDPOINT (host LAN IP), and ports / paths as needed

./scripts/deploy.sh
./scripts/smoke-test.sh
```

Full agent playbook: [AGENTS.md](AGENTS.md).

### Lab without a trusted TLS cert

Set `HARBOR_EXTERNAL_URL=http://<host>:<HTTP_PORT>` (e.g. `http://registry.example.local:8088`). That clears Harbor’s CSRF `Secure` cookie flag so the UI login works in a normal browser. Use the same host:port for `docker login` / push and add it to the client’s `insecure-registries` (rootless: `~/.config/docker/daemon.json`).

### Behind Caddy (or another TLS terminator)

```bash
NGINX_ENABLE_HTTPS=false
PROXY_HTTP_BIND=127.0.0.1
HTTP_PORT=8088
HARBOR_EXTERNAL_URL=https://registry.example.local   # public URL clients use
```

Point Caddy at `http://127.0.0.1:8088` and forward `Host` + `X-Forwarded-Proto`. Harbor nginx stays HTTP-only; no self-signed cert required on the Compose proxy.

## Layout

```
versions.env              # pinned Garage + DHI image tags
.env.example              # copy to .env
garage/                   # binary install + bootstrap
harbor/
  docker-compose.yml      # base stack (HTTP proxy)
  docker-compose.https.yml # optional HTTPS publish
  prepare.sh              # render configs/secrets into generated/
  templates/              # nginx, registry S3→Garage, etc.
scripts/deploy.sh         # one-shot bring-up
scripts/smoke-test.sh
data/                     # default runtime data (gitignored)
```

## Prerequisites

- Linux x86_64 or aarch64
- Docker Engine 20.10+ with Compose v2
- `curl`, `python3`
- `sudo` for Garage systemd install
- Docker Hub account (for `docker login dhi.io`)
- Recommended: 4 CPU / 8–16 GB RAM / 200+ GB disk

## Day-2

```bash
# Logs (include https override when NGINX_ENABLE_HTTPS=true)
set -a; source harbor/.env; set +a
docker compose ${COMPOSE_FILES} --env-file harbor/.env logs -f core

# Stop Harbor (Garage keeps running)
./scripts/down.sh

# Upgrade DHI tags: edit versions.env → ./harbor/prepare.sh → compose pull && up -d
# Backup: $HARBOR_DATA_DIR and $GARAGE_{META,DATA}_DIR plus .env / harbor/secrets
```

## Security notes

- DHI pulls require authentication to `dhi.io`.
- When `NGINX_ENABLE_HTTPS=true`, default TLS is self-signed (`harbor/secrets/tls/`). Replace with real certs and re-run `harbor/prepare.sh` (or overwrite those files).
- Lab HTTP mode and HTTP-only-behind-Caddy are for controlled environments; prefer HTTPS with a real (or trusted) cert in production.
- Never commit `.env`, `harbor/secrets/`, or `harbor/generated/`.
