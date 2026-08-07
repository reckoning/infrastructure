# Migration runbook: legacy Capistrano → Kamal on Hetzner

Cutover from the Ansible/Capistrano setup (`reckoning/infrastructure-legacy`) to this repo. Read it end to end before starting; steps 1–5 are non-destructive and can be done days ahead.

## What moves

| | From | To |
|---|---|---|
| App | Capistrano release dirs + nginx + rbenv | Kamal on Docker |
| Postgres | Server-installed Postgres | `db` Kamal accessory (Docker volume) |
| Redis | Server-installed Redis | `redis` Kamal accessory |
| Active Storage | Local archive of the retired DigitalOcean Spaces bucket | Hetzner Object Storage (`reckoning-live-storage`) |
| DNS | Existing `reckoning.me` nameservers | Hetzner DNS |
| Backups | Ansible `backup` role | `postgres-backup-s3` accessory → `reckoning-live-backups` |

## 1. Prerequisites

- 1Password `Reckoning` vault populated (see the table in [README.md](../README.md#secrets))
- `reckoning-terraform-state` bucket created once by hand in Hetzner Object Storage (nbg1)
- Hetzner S3 credentials exported as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
- `rclone` installed locally (`brew install rclone`)
- The current production dump available in your dev environment
- The Active Storage archive (zip) downloaded from the retired Spaces bucket

Both come from the pre-migration backup set (kept off-repo, in the operator's own backup storage):

| File | What it is |
|---|---|
| `files.zip` | **The Active Storage export.** ~100 blobs under a `files/` wrapper, keys in Active Storage's 28-char base36 format. This is the one step 5 wants. |
| `reckoning-pg17-*.sql` | Most recent production database dump. Use this for step 4. |
| `app/archives/files.tar.gz` | **Not** the blobs — six files from the old Capistrano `shared/public/uploads/`, last written Sep 2022, predating Active Storage. Nothing in the current app reads this path. |
| `app.tar`, `app.tar.gpg` | Ansible-era whole-app archives, superseded. |

> **The Spaces bucket is gone**, so the archive cannot be re-pulled. Keep an
> untouched copy for the duration of the migration and verify completeness
> before relying on it.

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

## 5. Upload Active Storage blobs

The Spaces bucket has already been retired, so the blobs come from the archive
rather than a live sync:

```bash
./scripts/import-storage.sh ~/Downloads/reckoning-storage.zip live --dry-run
./scripts/import-storage.sh ~/Downloads/reckoning-storage.zip live
```

Active Storage resolves blobs by their exact key with no prefix. If the zip wraps
the blobs in a folder, uploading it verbatim would put every object one level too
deep and silently break every attachment — the script detects and strips wrapper
directories, then prints a sample of the keys before writing anything. Check that
sample against the database:

```bash
kamal app exec -d live "bin/rails runner 'puts ActiveStorage::Blob.limit(5).pluck(:key)'"
```

Those keys must look like the sample the script printed. If they don't match, stop
and work out the layout before uploading.

Because the source bucket is gone, verify coverage rather than assuming it — a
blob missing here is permanently missing:

```bash
kamal app exec -d live "bin/rails runner '
  missing = ActiveStorage::Blob.find_each.reject { |b| b.service.exist?(b.key) }
  puts \"missing: #{missing.count}\"
  missing.first(10).each { |b| puts b.key }
'"
```

Then point the app at the new bucket. The `:hetzner` service and the
`hetzner_s3_key`/`hetzner_s3_secret` credentials already exist in the app repo —
only the selection still has to change, in `config/environments/production.rb`:

```ruby
config.active_storage.service = :hetzner
```

At the same time, drop the now-dead `:digitalocean` block from
`config/storage.yml` and the `s3_key`/`s3_secret` credentials with it.

Active Storage blob keys are preserved by the upload, so no database rewrite is
needed.

## 6. Cutover window

1. Put the old site into maintenance mode.
2. Take a final dump from the old production database and re-run step 4 — this catches everything written since the bulk import.
3. If the old site accepted uploads after the archive was taken, collect those blobs from the old server and re-run `./scripts/import-storage.sh` on them. `rclone copy` is additive, so re-running is safe.
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
- [ ] Active Storage archive verified complete (zero missing blobs) before it is deleted anywhere
- [ ] Capistrano gems and `config/deploy.rb` / `Capfile` removed from the app repo
- [ ] `deploy.job.yml` deleted and `kamal-deploy.yml` wired into the app's `main.yml`
- [ ] Verify a `db-backup` run has landed in `s3://reckoning-live-backups/`

## Rollback

Until step 7, the old stack is untouched and still authoritative — roll back by simply not switching DNS. After step 7, roll back by repointing nameservers; keep the old server running for at least one TTL cycle.
