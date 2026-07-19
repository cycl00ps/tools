# Linkwarden (self-hosted Docker)

Docker Compose layout for running [Linkwarden](https://docs.linkwarden.app/) with:

- **Postgres** — `dhi.io/postgres:16-alpine3.23` (Docker Hardened Images)
- **Meilisearch** — full-text / advanced search
- **Linkwarden** — web app + background worker (`ghcr.io/linkwarden/linkwarden`)

Data is stored on the host under a configurable root via named volumes with bind `device` paths.

## Files

| File | Purpose |
| --- | --- |
| `docker-compose.yaml` | Services, network, and volume binds |
| `setup.sh` | Creates data dirs, ownership, `.env` keys, Docker/DHI checks |
| `.env.example` | Template for environment variables |
| `.env` | Local secrets and host paths (**not committed**) |
| `.gitignore` | Keeps `.env` and credential files out of git |

## Prerequisites

- Docker Engine with Compose plugin (rootless or rootful)
- Ability to pull `dhi.io/postgres:16-alpine3.23` — log in first if needed:

```bash
docker login dhi.io
```

Credentials are not stored in this repository. `setup.sh` only verifies that auth already works.

## Data path (`LINKWARDEN_DATA_ROOT`)

Compose mounts:

```text
${LINKWARDEN_DATA_ROOT}/postgres      → Postgres data
${LINKWARDEN_DATA_ROOT}/meilisearch   → Meilisearch data
${LINKWARDEN_DATA_ROOT}/linkwarden    → Linkwarden archives / uploads
```

Default root: `/fast/docker-appdata/linkwarden`

**Set it in either place:**

1. When running setup (recommended for first-time host prep):

```bash
LINKWARDEN_DATA_ROOT=/path/to/linkwarden-data ./setup.sh
```

2. Or in `.env` (Compose reads this for `${LINKWARDEN_DATA_ROOT}` interpolation):

```bash
LINKWARDEN_DATA_ROOT=/path/to/linkwarden-data
```

`setup.sh` upserts `LINKWARDEN_DATA_ROOT` into `.env` so Compose and the script stay aligned.

## Quick start

```bash
# 1. Prep host (dirs, ownership, .env secrets, DHI check)
./setup.sh

# 2. Start the stack
docker compose up -d

# 3. Open the UI
# http://localhost:3000
```

There is no default login. Use **Sign up** to create the first account (that user is admin).

To stop:

```bash
docker compose down
```

## Environment variables

Copy from the example if needed (setup does this automatically when `.env` is missing):

```bash
cp .env.example .env
```

Required for a basic deploy:

| Variable | Notes |
| --- | --- |
| `LINKWARDEN_DATA_ROOT` | Host directory for volume binds |
| `NEXTAUTH_URL` | Must end with `/api/v1/auth` (e.g. `http://localhost:3000/api/v1/auth`) |
| `NEXTAUTH_SECRET` | Long random secret (`setup.sh` generates if empty) |
| `MEILI_MASTER_KEY` | Meilisearch master key (`setup.sh` generates if empty) |
| `POSTGRES_PASSWORD` | Postgres password; also used in Compose `DATABASE_URL` |

`MEILI_HOST` defaults to `http://meilisearch:7700` inside the Compose network when unset.

### Optional AI tagging

Add an OpenAI-compatible provider to `.env`:

```bash
CUSTOM_OPENAI_BASE_URL=https://example.com/v1
OPENAI_MODEL=your-model-id
OPENAI_API_KEY=sk-...
```

Then:

1. Recreate the app container so env is picked up (see below).
2. In the UI: **Settings → Preferences** → enable AI tagging (e.g. auto-generate tags).

Use a model that returns normal assistant `content`. Some “reasoning” models only fill `reasoning_content`; Linkwarden does not send disable-thinking flags, so those models often produce no tags.

## Operations

### After changing `.env`

A plain `docker compose restart` does **not** reload environment variables. Recreate:

```bash
docker compose up -d --force-recreate
```

### Postgres permissions

DHI Postgres runs as UID/GID **70** in the container. Under rootless Docker that maps to a subordinate host UID. `setup.sh` creates the data directories and applies the correct ownership; re-run it if you change `LINKWARDEN_DATA_ROOT` or recreate empty postgres storage.

### Useful commands

```bash
docker compose ps
docker compose logs -f linkwarden
docker compose pull && docker compose up -d
```

## Upstream docs

- [Installation](https://docs.linkwarden.app/self-hosting/installation)
- [Environment variables](https://docs.linkwarden.app/self-hosting/environment-variables)
- [AI tagging](https://docs.linkwarden.app/self-hosting/ai-worker)
