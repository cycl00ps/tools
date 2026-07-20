# OpenBao (Docker Compose)

Single-node OpenBao on the official image (`openbao/openbao`, includes Web UI), Integrated Storage (Raft), and Shamir seal. Listens on plain HTTP on localhost only; put Caddy (or another HTTPS proxy) in front.

```
Client → Caddy (HTTPS) → 127.0.0.1:9092 → openbao :8200 (network: openbao)
```

Host persistent paths (default):

```
/fast/docker-appdata/openbao/
├── config/config.hcl
└── data/                 # Raft state
```

Override with `OPENBAO_APPDATA` (see Deploy).

## Prerequisites

- Docker Compose
- OpenBao CLI (`bao`) on the host optional but handy for init/unseal

## Repo layout

```
.
├── docker-compose.yml
├── prep-host.sh         # host prep for rootless Docker
├── config/config.hcl    # template — installed into appdata by prep-host.sh
├── .env.example         # OPENBAO_APPDATA default
├── .gitignore
└── README.md
```

## Deploy

On the target host (Docker already installed **rootless**), from this repo directory:

```bash
cp .env.example .env
# optional: edit OPENBAO_APPDATA=/your/custom/path

# prep-host.sh does not auto-load Compose .env — pass the same path:
export OPENBAO_APPDATA=/fast/docker-appdata/openbao   # or your custom path
./prep-host.sh               # creates ${OPENBAO_APPDATA}/{config,data},
                             # copies config, sets rootless-mapped ownership for uid 100
docker compose up -d
docker compose logs -f openbao
```

`prep-host.sh` maps container UID/GID `100`/`1000` (official `openbao` user) to the correct host subordinate IDs from `/etc/subuid` and `/etc/subgid` (rootless: `subuid + n - 1`).

Compose publishes **only** `127.0.0.1:9092` → container `8200`. Cluster port 8201 stays internal (single node). Point Caddy at `http://127.0.0.1:9092`. OpenBao TLS is disabled on purpose (`tls_disable = true`).

When Caddy serves a public HTTPS hostname, update `api_addr` in `config/config.hcl` to that URL, re-run `./prep-host.sh` (or copy the config into appdata), and recreate the container so UI redirects match.

### Health check

From the host:

```bash
curl -s http://127.0.0.1:9092/v1/sys/health
# or with the CLI:
export BAO_ADDR=http://127.0.0.1:9092
bao status
```

## Initialize and unseal (Shamir)

First start only — creates cryptographically strong Shamir shares and a root token. **Store them offline**; they are not recoverable from disk alone. Default is **5 shares / threshold 3** (do not use 1-of-1 in production).

```bash
export BAO_ADDR=http://127.0.0.1:9092

bao operator init
# Note Unseal Key 1..5 and Initial Root Token — store offline; never commit

bao operator unseal   # paste key 1
bao operator unseal   # paste key 2
bao operator unseal   # paste key 3
# … until threshold is met

bao status            # Sealed: false
```

After every container restart, OpenBao starts **sealed**. Unseal again with the same share threshold.

When ready for application secrets:

```bash
bao login               # use root token once, then create limited policies
bao secrets enable -path=secret kv-v2
bao kv put secret/example password=changeme
```

## Shamir vs auto-unseal

| | Shamir (this deploy) | Auto-unseal |
|---|---|---|
| How the root key is protected | Split into N shares; M required to unseal | Wrapped by an external KMS, HSM, or Transit |
| After restart | Manual `bao operator unseal` × threshold | Unseals automatically if the seal provider is reachable |
| Ops burden | Guard and distribute key shares | IAM, key rotation, and availability of the KMS |
| Failure mode | Stuck sealed until operators enter shares | Stuck sealed if KMS is down or the key is deleted |
| Init output | Unseal key shares + root token | Recovery keys + root token |

This stack uses **Shamir** so there is no cloud KMS dependency. Migrating later is a seal migration with downtime; see [OpenBao seal docs](https://openbao.org/docs/concepts/seal/).

## Raft storage options and layout

OpenBao must persist encrypted data somewhere. The main production-ready choices:

| Backend | When to use |
|---|---|
| **Integrated Storage (Raft)** — used here | Simplest: no extra database; local disk; HA later via peer join; native snapshots |
| PostgreSQL | You already run Postgres and want storage off the OpenBao host |
| `file` | **Avoid** — not recommended for production; deprecated/non-transactional |

### This deploy’s layout

```
${OPENBAO_APPDATA}/config/config.hcl  → /openbao/config/config.hcl (read-only)
${OPENBAO_APPDATA}/data/              → /openbao/data   (Raft path)
└── raft/ …                           # created by OpenBao after init
```

Default `OPENBAO_APPDATA` is `/fast/docker-appdata/openbao`.

- Persist the entire `data/` directory across upgrades.
- Losing `data/` loses the cluster (ciphertext without the seal keys is still unusable for recovery of secrets you care about operationally).
- Backup while unsealed:

  ```bash
  bao operator raft snapshot save backup-$(date +%Y%m%d).snap
  ```

- Multi-node later: add peers with `retry_join` / `bao operator raft join` and allow cluster traffic on **8201 between nodes only**. This Compose file does not publish 8201.

## Image notes

- Image: `openbao/openbao:2.6.0` (includes Web UI).
- Runs as non-root uid **100** / gid **1000**.
- Compose overrides `entrypoint` to `bao` so the stock script does not inject `-dev-listen-address` (that conflicts with `config.hcl`’s listener).
- Use the host CLI against `BAO_ADDR`, or `docker compose exec openbao bao …`.

## References

- [OpenBao Docker Hub](https://hub.docker.com/r/openbao/openbao)
- [Configuration](https://openbao.org/docs/configuration/)
- [Integrated Storage (Raft)](https://openbao.org/docs/configuration/storage/raft/)
- [Seal / unseal](https://openbao.org/docs/concepts/seal/)
