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
| Object Storage | 0.00* | See below |
| **Live total** | **~4.60** | |
| Stage | 0.00 | Nothing provisioned until spun up |

\* [Hetzner's Object Storage base price is per **account**](https://docs.hetzner.com/storage/object-storage/overview/), not per bucket or per project: *"You are charged per hour with a monthly price cap, regardless of how many Buckets you have and how many different projects or locations they are in."* Roughly €4.99/month includes 1 TB of storage and 1 TB of egress, pooled across every bucket in the account.

So reckoning's storage is free **if the account already pays that base price for another project**. Reckoning's own footprint — ~100 Active Storage blobs totalling ~5 MB, plus ~1 MB/day of retained database dumps — is a rounding error against the included terabyte. If reckoning is the first thing on the account to create a bucket, add ~4.99 to the table: the charge starts at the first active bucket, even an empty one.

Splitting stage and live into two Hetzner **projects costs nothing**. Billing is per account; projects are only an organisational boundary.

Levers, cheapest first:

1. **Stage holds nothing when idle.** `web_servers_count = 0` and `object_storage = false`.
2. **One server, not two.** `accessories_count = 0` (the default for live) colocates the datastores. The trade-off is that replacing the web server destroys the Postgres volume — see [MAINTENANCE.md](MAINTENANCE.md).
3. **ARM instead of Intel.** A `cax11` is cheaper than a `cx23` for the same 2 vCPU / 4 GB. This requires changing `builder.arch` to `arm64` in the app repo's `config/deploy.yml`; not done by default because the Docker image is currently built `amd64`.

Bucket *count* is not a lever — that is why `separate_backup_bucket` defaults to `true`. Keeping database dumps out of the bucket that carries the app's CORS rules is free.

## Workspaces and Hetzner projects

One Hetzner account, one project per environment. A Hetzner API token is scoped to a single project, so the token selects the project — there is nothing else to configure.

| Workspace | Hetzner project | Domain | Servers |
|---|---|---|---|
| `default` | — | — | 1 web + 1 accessories (used by `terraform test` only) |
| `stage` | `reckoning-stage` | `stage.reckoning.me` | 0 (scale up on demand) |
| `live` | `reckoning-live` | `reckoning.me`, `www`, `*` | 1 web (colocated datastores) |

Three things are per-project in Hetzner and trip people up:

- **SSH keys.** The key named by the `SSH Config` 1Password item must exist in *both* projects, under the same name. `data.hcloud_ssh_key.by_name` fails the plan otherwise.
- **Object Storage credentials.** Buckets live in a project, so a key pair only works against its own project's buckets. Only live has buckets today, so a single `HETZNER_S3` item covers it; a stage that enables `object_storage` needs its own item. Terraform reads these explicitly, because `AWS_ACCESS_KEY_ID` is claimed by the state backend.
- **The state bucket.** `reckoning-terraform-state` lives in the **live** project and holds both workspaces' state. `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in your environment are the *live project's* credentials, used only by the backend.

`stage` and `live` share the `reckoning.me` DNS zone. Hetzner DNS zones are account-level rather than project-level, so this works across the two projects — but only the workspace named by `dns_zone_owner_workspace` (default `live`) manages the `hcloud_zone` resource; `stage` writes its records into the same zone.

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
| `scripts/` | Vault readiness check, DB import, Active Storage blob upload |
| `tests/` | `terraform test` suites |

## Secrets

All credentials come from the **`Reckoning` 1Password vault** — nothing is stored in tfvars. Required items:

Values must go in the item's **top-level** `username` / `credential` / public-key fields. The Terraform provider only exposes those as attributes; a value tucked into a custom field reads back as an empty string and fails at apply time in a confusing way.

| Item | Fields used | Purpose |
|---|---|---|
| `HCLOUD_LIVE` | credential | Hetzner API token, `reckoning-live` project |
| `HCLOUD_STAGE` | credential | Hetzner API token, `reckoning-stage` project |
| `HETZNER_S3` | username, credential | Object Storage access key + secret. Only read by workspaces with `object_storage = true`. |
| `SSH Config` | username | Name of the SSH key — must exist in **both** projects |
| `Deploy Key Live` | public key | Injected into `authorized_keys` for the `kamal` user |
| `Deploy Key Stage` | public key | Same, for stage |
| `APPSIGNAL` | credential | AppSignal push API key (set `enable_appsignal = false` to skip) |

Locally, authenticate with the 1Password CLI (`op signin`). In CI, set `OP_SERVICE_ACCOUNT_TOKEN`.

Check what is still outstanding at any point — it reports SET/EMPTY per field and never prints values:

```bash
./scripts/check-vault.sh
```

## Usage

```bash
# One-time: create the state bucket in the reckoning-live project's
# Object Storage: reckoning-terraform-state (nbg1)
#
# These are the LIVE project's S3 credentials and are used only by the state
# backend. Per-workspace bucket credentials come from 1Password.
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...

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
