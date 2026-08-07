# Reckoning Infrastructure

Terraform-managed infrastructure for Reckoning on Hetzner Cloud, deployed with Kamal. Secrets come from 1Password; state lives in Hetzner Object Storage.

## Overview

Live is a **single server** running the Rails app, Sidekiq worker, Postgres, and Redis as Kamal accessories behind `kamal-proxy`. Stage is scaled to zero. The module also supports a split web/accessories topology and a load-balanced multi-web topology — both are driven entirely by `env_config` in `variables.tf`.

Read [README.md](README.md) for architecture and the cost model, [MAINTENANCE.md](MAINTENANCE.md) for operational procedures, [docs/migration.md](docs/migration.md) for the legacy cutover.

Stage and live are separate **Hetzner projects** (`reckoning-stage`, `reckoning-live`) under one account. The API token selects the project, so workspace switching is all that's needed — but SSH keys and Object Storage credentials are per-project, and the state bucket lives in the live project. See the workspaces section of README.md before touching provider or backend config.

## Constraints

- **Cost is a first-class constraint.** Reckoning runs on the cheapest workable setup. Don't add servers, buckets, load balancers, or CDN zones without a stated reason — every one of them has a monthly bill. The cost ladder in README.md explains what was traded away and why.
- **Verify pricing before designing around it.** Hetzner's Object Storage base price is per *account* and covers any number of buckets across any number of projects — an earlier version of this repo assumed a per-bucket fee and contorted the config to avoid a cost that does not exist. Cite the docs when a cost claim drives a design decision.
- **A scaled-to-zero environment provisions nothing.** `env_config.object_storage` gates the buckets separately from `web_servers_count`, and there is a test asserting it. This is resource hygiene rather than a cost saving, but keep it.
- **The live web server holds the database volume.** Anything that replaces it is data loss. Never remove `lifecycle { ignore_changes = [user_data] }` from `hcloud_server`, and never weaken the destructive-change gate in `.github/workflows/deploy.yml`.
- **`manage_dns` defaults to `false`.** `reckoning.me` is still served by its existing nameservers. Do not flip the default.
- **Mail DNS (`var.email_config`) is deliberately empty.** Never invent MX, DKIM, or SPF values — wrong records break invoice delivery silently. They must be transcribed from the live zone.
- **The Active Storage archive is irreplaceable.** The DigitalOcean Spaces bucket it came from has been retired, so the zip is the only copy of every invoice attachment. `scripts/import-storage.sh` uses `rclone copy`, never `sync`, and verifies coverage rather than assuming it. Don't relax either.

## Key files

| File | Purpose |
|---|---|
| `cloud.tf` | Servers, network, firewalls, load balancer, managed certs |
| `dns.tf` | Hetzner DNS zone and records |
| `storage.tf` | Object storage buckets + CORS |
| `secrets.tf` | 1Password vault and item lookups |
| `data.tf` | Cloud-init composition per server role |
| `variables.tf` | Inputs and per-workspace config (`env_config`) |
| `locals.tf` | Computed values (private IPs, `colocated_datastores`) |
| `versions.tf` | Version constraints and the S3 state backend |
| `cloudinit/` | `base` + `web` / `datastore` / `appsignal` fragments |
| `scripts/` | Vault readiness check, DB import, Active Storage blob upload |
| `tests/` | `terraform test` suites |

## Commands

```bash
terraform init -backend=false   # no credentials needed, enough for validate/test
terraform validate
terraform test
terraform fmt -recursive

terraform workspace select live
terraform plan
terraform apply
```

CI enforces `fmt -check -recursive`, `validate`, `test`, and `shellcheck scripts/*.sh`. Run them locally before pushing.

## Conventions

- Resource names are prefixed with `local.prefix` (`reckoning-<workspace>`) so nothing collides between workspaces.
- Firewall and load balancer label selectors are scoped with `env=${terraform.workspace}`.
- Per-workspace differences belong in `env_config`, not in `count`/`for_each` conditionals scattered across files.
- New behaviour that varies by topology should be derived in `locals.tf` (see `colocated_datastores`) rather than re-testing `accessories_count == 0` inline.
- Add a `terraform test` assertion for anything with a conditional — the existing suite already caught an empty-CORS bug that `validate` did not.

## Related repos

- [reckoning/reckoning](https://github.com/reckoning/reckoning) — the Rails app; owns `config/deploy.yml` and the Kamal accessories (see [docs/kamal-accessories.md](docs/kamal-accessories.md))
- [reckoning/infrastructure-legacy](https://github.com/reckoning/infrastructure-legacy) — archived Ansible setup, no longer applied
