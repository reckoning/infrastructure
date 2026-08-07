# Reckoning Infrastructure

Terraform-managed infrastructure for [Reckoning](https://github.com/reckoning/reckoning) on Hetzner Cloud, deployed with [Kamal](https://kamal-deploy.org).

Replaces the Ansible setup in [reckoning/infrastructure-legacy](https://github.com/reckoning/infrastructure-legacy), which is archived and no longer applied.

## Architecture

Reckoning is a small single-tenant Rails app, so live runs as **one server**: the Rails web container, the Sidekiq worker, Postgres, and Redis all sit on the same box as Kamal accessories, behind `kamal-proxy` for TLS.

```
                 ┌─────────────────────────────────┐
   :443 ────────►│  reckoning-live-web  (cx23)     │
                 │  ├─ kamal-proxy (TLS, /up)      │
                 │  ├─ web      (Rails, :8240)     │
                 │  ├─ worker   (Sidekiq)          │
                 │  ├─ db       (Postgres 16)      │
                 │  ├─ redis    (Redis 7)          │
                 │  └─ db-backup ──► S3 (db/)      │
                 └─────────────────────────────────┘
```

The module still supports the split web/accessories topology used by FleetYards — set `accessories_count = 1` for the workspace and Postgres/Redis move to a private box reachable only via ProxyJump. Cloud-init adapts automatically (see `local.colocated_datastores`).

Scaling `web_servers_count` above 1 provisions a load balancer with Hetzner managed certificates and switches TLS termination from kamal-proxy to the LB.

## Cost

Reckoning is optimised for the cheapest workable live setup. Approximate monthly EUR, **verify against current Hetzner pricing before relying on these**:

| Item | Cost | Notes |
|---|---|---|
| 1× cx23 web server | ~4.00 | Runs everything |
| Primary IPv4 | ~0.60 | Required for public HTTPS |
| Object storage bucket | ~6.00 | Flat per-bucket fee, 1 TB included |
| **Live total** | **~10.60** | |
| Stage | 0.00 | `web_servers_count = 0` — scaled to zero until needed |

Levers, cheapest first:

1. **Stage is scaled to zero by default.** Bump `web_servers_count` in `variables.tf`, apply, use it, scale back down.
2. **One bucket, not two.** `separate_backup_bucket = false` (the default) keeps Postgres backups in the storage bucket under a `db/` prefix instead of paying a second per-bucket fee.
3. **One server, not two.** `accessories_count = 0` (the default for live) colocates the datastores. The trade-off is that replacing the web server destroys the Postgres volume — see [MAINTENANCE.md](MAINTENANCE.md).
4. **ARM instead of Intel.** A `cax11` is cheaper than a `cx23` for the same 2 vCPU / 4 GB. This requires changing `builder.arch` to `arm64` in the app repo's `config/deploy.yml`; not done by default because the Docker image is currently built `amd64`.

## Workspaces

| Workspace | Domain | Servers |
|---|---|---|
| `default` | — | 1 web + 1 accessories (used by `terraform test` only) |
| `stage` | `stage.reckoning.me` | 0 (scale up on demand) |
| `live` | `reckoning.me`, `www`, `*` | 1 web (colocated datastores) |

`stage` and `live` share the `reckoning.me` DNS zone. Only the workspace named by `dns_zone_owner_workspace` (default `live`) manages the `hcloud_zone` resource; `stage` writes its records into the same zone.

## Key files

| File | Purpose |
|---|---|
| `cloud.tf` | Servers, network, firewalls, load balancer, managed certs |
| `dns.tf` | Hetzner DNS zone and records |
| `storage.tf` | Object storage buckets + CORS |
| `secrets.tf` | 1Password vault and item lookups |
| `data.tf` | Cloud-init composition per server role |
| `variables.tf` | Inputs and per-workspace config (`env_config`) |
| `locals.tf` | Computed values (private IPs, colocation flag) |
| `versions.tf` | Version constraints and the S3 state backend |
| `cloudinit/` | `base` + `web` / `datastore` / `appsignal` fragments |
| `scripts/` | DB import and Active Storage blob upload |
| `tests/` | `terraform test` suites |

## Secrets

All credentials come from the **`Reckoning` 1Password vault** — nothing is stored in tfvars. Required items:

| Item | Fields used | Purpose |
|---|---|---|
| `HCLOUD_LIVE` | credential | Hetzner API token (live) |
| `HCLOUD_STAGE` | credential | Hetzner API token (stage) |
| `SSH Config` | username | Name of the SSH key in the Hetzner console |
| `Deploy Key Live` | public key | Injected into `authorized_keys` for the `kamal` user |
| `Deploy Key Stage` | public key | Same, for stage |
| `APPSIGNAL` | credential | AppSignal push API key (set `enable_appsignal = false` to skip) |

Locally, authenticate with the 1Password CLI (`op signin`). In CI, set `OP_SERVICE_ACCOUNT_TOKEN`.

## Usage

```bash
# One-time: create the state bucket in Hetzner Object Storage
#   reckoning-terraform-state (fsn1)
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # Hetzner S3 credentials

terraform init
terraform workspace select live      # or: terraform workspace new live

terraform plan
terraform apply

# SSH config for ~/.ssh/config
terraform output -raw ssh_web_server_config
```

Run `terraform fmt -recursive`, `terraform validate`, and `terraform test` before pushing — CI enforces all three.

## CI/CD

- **Main** (`.github/workflows/main.yml`) — `fmt -check`, `validate`, `test`, and ShellCheck on every push and PR.
- **Deploy** (`.github/workflows/deploy.yml`) — applies `stage` automatically after a green Main on `main`. `live` is `workflow_dispatch` only and runs plan → destructive-change gate → a separate `Live` environment approval → apply. Because the live web server holds the Postgres volume, any plan containing a destroy or replace fails the gate and must be applied by hand.

## Migrating off the legacy setup

See [docs/migration.md](docs/migration.md) for the cutover runbook: importing the existing production database, uploading the Active Storage archive, and repointing DNS.
