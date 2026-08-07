# Server Maintenance

Servers run Ubuntu 24.04 on Hetzner Cloud, provisioned by Terraform and deployed with Kamal.

## The single-node caveat

Live is one server, and it carries the Postgres and Redis Docker volumes. Everything below follows from that:

- **Replacing the server destroys the database.** Always restore from backup afterwards.
- **Rebooting means downtime.** There is no second node to drain to.
- `hcloud_server` has `lifecycle { ignore_changes = [user_data] }`, so cloud-init edits never silently trigger a replace. Replacement is always deliberate (`terraform taint`).
- The live CI apply blocks any plan containing a destroy or replace. That gate exists for exactly this reason — if you hit it, work out *why* something is being replaced before overriding it.

## Access

```bash
terraform output -raw ssh_web_server_config >> ~/.ssh/config
ssh kamal@<web-ip>
```

With a split topology (`accessories_count > 0`), accessory servers have no public ingress and are reached via ProxyJump:

```bash
ssh -J kamal@<web-ip> kamal@<accessory-ip>
```

## Automated security patches

`unattended-upgrades` is installed by cloud-init and applies Ubuntu security updates daily.

```bash
sudo unattended-upgrades --dry-run        # what would be upgraded
cat /var/log/unattended-upgrades/unattended-upgrades.log
ls /var/run/reboot-required               # is a reboot pending?
```

Not automated: non-security packages, kernel reboots, Docker updates, major OS upgrades.

## Manual package updates

Run monthly, or after a security advisory.

```bash
ssh kamal@<web-ip> "sudo apt update && sudo apt upgrade -y"
```

## Docker updates

Updating Docker restarts the daemon and stops every container, including Postgres. Expect downtime.

```bash
# Confirm a recent backup exists first
ssh kamal@<web-ip> "docker exec reckoning-db-backup /backup.sh"

ssh kamal@<web-ip> "sudo apt update && sudo apt install -y docker.io"
kamal deploy -d live
```

## Reboots

```bash
ssh kamal@<web-ip> "sudo reboot"
# wait, then verify
ssh kamal@<web-ip> "uptime && docker ps"
curl -s https://reckoning.me/up
```

Kamal accessories restart automatically (`--restart unless-stopped`); the app container is brought back by `kamal deploy` if it doesn't come up on its own.

## Maintenance mode

`kamal-proxy` can serve a maintenance page:

```bash
kamal app stop -d live      # proxy returns 503
kamal app boot -d live
```

If you later run behind a load balancer, set `maintenance = true` so LB health checks accept 503 and don't pull the node out entirely.

## Replacing the server (OS upgrades, base config changes)

1. **Back up and verify** — do not skip the verify:
   ```bash
   ssh kamal@<web-ip> "docker exec reckoning-db-backup /backup.sh"
   aws s3 ls s3://reckoning-live-storage/db/ --endpoint-url https://fsn1.your-objectstorage.com
   ```
   Pull the dump down locally as well. One copy in one place is not a backup.

2. Update `variable "operating_system"` in `variables.tf`.

3. Taint and plan:
   ```bash
   terraform workspace select live
   terraform taint 'hcloud_server.web_server[0]'
   terraform plan
   ```
   Confirm only the server is being replaced — network, DNS, and buckets should be unchanged.

4. Apply locally (CI blocks destructive live plans by design).

5. Rebuild and restore:
   ```bash
   kamal setup -d live
   ./scripts/import-db.sh <latest-backup>.sql.gz live
   kamal app exec -d live "bin/rails db:migrate"
   ```

6. Update DNS if the IP changed — `terraform apply` handles the A records when `manage_dns = true`.

## Checklists

Before maintenance:

- [ ] Recent backup exists in `s3://reckoning-live-storage/db/` **and** a copy is downloaded
- [ ] `terraform output` noted (IPs)
- [ ] Scheduled outside business hours — invoicing users notice

After maintenance:

- [ ] `curl -s https://reckoning.me/up` returns 200
- [ ] `docker ps` shows web, worker, db, redis, db-backup, kamal-proxy
- [ ] An invoice PDF renders (exercises DB + Active Storage together)
- [ ] `ls /var/run/reboot-required` is empty
