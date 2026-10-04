# Harbor (DHI) + Garage — private container registry

On-prem Docker/OCI registry using:

| Layer | Component |
|-------|-----------|
| Registry UI / API / scanning | **Harbor 2.15** as **Docker Hardened Images** (`dhi.io/harbor-*`) |
| Orchestration | **Docker Compose** (this repo) |
| Object storage | **Garage** binary, single-node, systemd |

No Kubernetes. No MinIO. Image blobs live in Garage (S3); Harbor DB/Redis/job logs use local bind mounts under `data/`.

## Quick deploy (human or agent)

```bash
cp .env.example .env
# Edit HARBOR_HOSTNAME, HARBOR_EXTERNAL_URL, HARBOR_ADMIN_PASSWORD, POSTGRES_PASSWORD

./scripts/deploy.sh
./scripts/smoke-test.sh
```

Full agent playbook: [AGENTS.md](AGENTS.md).

## Layout

```
versions.env              # pinned Garage + DHI image tags
.env.example              # copy to .env
garage/                   # binary install + bootstrap
harbor/
  docker-compose.yml      # deterministic DHI stack
  prepare.sh              # render configs/secrets into generated/
  templates/              # nginx, registry S3→Garage, etc.
scripts/deploy.sh         # one-shot bring-up
scripts/smoke-test.sh
data/                     # runtime data (gitignored)
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
# Logs
docker compose -f harbor/docker-compose.yml --env-file harbor/.env logs -f core

# Stop Harbor (Garage keeps running)
./scripts/down.sh

# Upgrade DHI tags: edit versions.env → ./harbor/prepare.sh → compose pull && up -d
# Backup: data/harbor/* and /var/lib/garage/{meta,data} plus .env / harbor/secrets
```

## Security notes

- DHI pulls require authentication to `dhi.io`.
- Default TLS is self-signed (`harbor/secrets/tls/`). Replace with real certs and re-run `harbor/prepare.sh` (or overwrite those files).
- Never commit `.env`, `harbor/secrets/`, or `harbor/generated/`.
