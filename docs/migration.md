# Migration runbook: legacy Capistrano → Kamal on Hetzner

Cutover from the Ansible/Capistrano setup (`reckoning/infrastructure-legacy`) to this repo. Read it end to end before starting; steps 1–5 are non-destructive and can be done days ahead.

## What moves

| | From | To |
|---|---|---|
| App | Capistrano release dirs + nginx + rbenv | Kamal on Docker |
| Postgres | Server-installed Postgres | `db` Kamal accessory (Docker volume) |
| Redis | Server-installed Redis | `redis` Kamal accessory |
| Active Storage | DigitalOcean Spaces (`reckoning`, fra1) | Hetzner Object Storage (`reckoning-live-storage`) |
| DNS | Existing `reckoning.me` nameservers | Hetzner DNS |
| Backups | Ansible `backup` role | `postgres-backup-s3` accessory → `db/` prefix |

## 1. Prerequisites

- 1Password `Reckoning` vault populated (see the table in [README.md](../README.md#secrets))
- `reckoning-terraform-state` bucket created once by hand in Hetzner Object Storage (fsn1)
- Hetzner S3 credentials exported as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
- `rclone` installed locally (`brew install rclone`)
- The current production dump available in your dev environment

## 2. Provision the server

`manage_dns` defaults to `false`, so this creates the server without touching live DNS.

```bash
terraform init
terraform workspace new live
terraform apply
terraform output -raw ssh_web_server_config >> ~/.ssh/config
```

Wait for cloud-init to finish, then confirm Docker and the `kamal` user are ready:

```bash
ssh kamal@<web-ip> "cloud-init status --wait && docker --version"
```

## 3. Bring up accessories and deploy

From the **app repo**, with `config/deploy.live.yml` pointing at the new server IP:

```bash
kamal setup -d live      # boots db, redis, db-backup, then deploys web + worker
```

At this point the app is running against an empty database and is reachable by IP only.

## 4. Import the production database

The dump you already hold in your dev environment goes straight into the `db` accessory. From **this repo**:

```bash
./scripts/import-db.sh ~/dumps/reckoning-production.dump live
```

The script drops and recreates the target database, so it prompts for confirmation. It handles `.dump` (custom format), `.sql`, and `.sql.gz`.

Then, from the app repo:

```bash
kamal app exec -d live "bin/rails db:migrate"
kamal app exec -d live "bin/rails runner 'puts [Invoice.count, Project.count, User.count].inspect'"
```

Compare those counts against the old production box before continuing.

> **Encrypted columns.** Reckoning uses Active Record encryption. The restored data is only readable if the new deployment has the same `RAILS_MASTER_KEY` and encryption keys as the old one — verify by reading back an encrypted attribute, not just by counting rows.

## 5. Move Active Storage off DigitalOcean

`rclone sync` is incremental, so run it once now to move the bulk:

```bash
export DO_SPACES_KEY=... DO_SPACES_SECRET=...
./scripts/migrate-storage.sh live --dry-run   # review first
./scripts/migrate-storage.sh live
```

Then point the app at the new bucket — add a Hetzner service to `config/storage.yml` in the app repo and switch `config.active_storage.service`:

```yaml
hetzner:
  service: S3
  bucket: reckoning-live-storage
  endpoint: https://fsn1.your-objectstorage.com
  region: fsn1
  access_key_id: <%= Rails.application.credentials.dig(:hetzner_s3_key) %>
  secret_access_key: <%= Rails.application.credentials.dig(:hetzner_s3_secret) %>
```

Active Storage blob keys are preserved by the sync, so no database rewrite is needed.

## 6. Cutover window

1. Put the old site into maintenance mode.
2. Take a final dump from the old production database and re-run step 4 — this catches everything written since the bulk import.
3. Re-run `./scripts/migrate-storage.sh live` to catch new blobs.
4. Deploy the app with the Hetzner storage service active: `kamal deploy -d live`.
5. Verify: `curl -s https://<web-ip>/up`, log in, open an invoice PDF (exercises both the DB and Active Storage).

## 7. DNS

Only after step 6 verifies clean.

```bash
# Transcribe the existing MX / DKIM / TXT records into var.email_config first —
# these are left empty on purpose so mail delivery can't silently break.
terraform apply -var 'manage_dns=true'
```

Then repoint `reckoning.me` at Hetzner's nameservers at the registrar. Lower the TTL at the current provider ~24h beforehand.

Mail records must be in place *before* the nameserver switch, or invoice delivery breaks the moment DNS propagates.

## 8. Decommission

- [ ] Old server destroyed, final dump archived
- [ ] DigitalOcean Spaces bucket retained read-only for one backup cycle, then deleted
- [ ] Capistrano gems and `config/deploy.rb` / `Capfile` removed from the app repo
- [ ] `deploy.job.yml` deleted and `kamal-deploy.yml` wired into the app's `main.yml`
- [ ] Verify a `db-backup` run has landed in `s3://reckoning-live-storage/db/`

## Rollback

Until step 7, the old stack is untouched and still authoritative — roll back by simply not switching DNS. After step 7, roll back by repointing nameservers; keep the old server running for at least one TTL cycle.
