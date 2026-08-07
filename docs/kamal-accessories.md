# Kamal accessories for the app repo

`config/deploy.yml` in [reckoning/reckoning](https://github.com/reckoning/reckoning) currently declares no accessories — it assumes Postgres and Redis already exist externally. On this infrastructure they don't, so add the block below before running `kamal setup -d live`.

Because live is a single node (`accessories_count = 0`), the accessories are pinned to the web host. If you later split the datastores onto their own box, change `host:` to the accessory server's **private** IP from `terraform output -raw accessory_private_ips`.

```yaml
accessories:
  db:
    image: postgres:16
    host: <web server IP>
    port: "127.0.0.1:5432:5432"
    env:
      clear:
        POSTGRES_DB: reckoning_production
      secret:
        - POSTGRES_USER
        - POSTGRES_PASSWORD
    directories:
      - data:/var/lib/postgresql/data
    options:
      memory: 1g

  redis:
    image: redis:7.2
    host: <web server IP>
    port: "127.0.0.1:6379:6379"
    cmd: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru
    directories:
      - data:/data
    options:
      memory: 512m

  db-backup:
    image: eeshugerman/postgres-backup-s3:16
    host: <web server IP>
    env:
      clear:
        POSTGRES_HOST: reckoning-db
        POSTGRES_DATABASE: reckoning_production
        SCHEDULE: "0 3 * * *"
        S3_ENDPOINT: https://fsn1.your-objectstorage.com
        S3_BUCKET: reckoning-live-storage
        S3_PREFIX: db
        S3_REGION: fsn1
        BACKUP_KEEP_DAYS: 14
      secret:
        - POSTGRES_USER
        - POSTGRES_PASSWORD
        - S3_ACCESS_KEY_ID
        - S3_SECRET_ACCESS_KEY
    options:
      memory: 256m
```

Ports bind to `127.0.0.1` rather than `0.0.0.0` — on a colocated node the datastores must not be reachable from the public interface. The firewall only opens 22/80/443, but the loopback binding means a firewall mistake isn't immediately an open database.

`S3_BUCKET`/`S3_PREFIX` match the defaults in `storage.tf`. If you flip `separate_backup_bucket = true`, use `terraform output backups_bucket` and `terraform output backups_prefix` instead.

The app also needs `.kamal/secrets`, which does not yet exist in the app repo:

```bash
SECRETS=$(kamal secrets fetch --adapter 1password --account my.1password.com --from Reckoning \
  RAILS_MASTER_KEY DATABASE_URL REDIS_URL POSTGRES_USER POSTGRES_PASSWORD \
  S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY)

KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
RAILS_MASTER_KEY=$(kamal secrets extract RAILS_MASTER_KEY ${SECRETS})
DATABASE_URL=$(kamal secrets extract DATABASE_URL ${SECRETS})
REDIS_URL=$(kamal secrets extract REDIS_URL ${SECRETS})
POSTGRES_USER=$(kamal secrets extract POSTGRES_USER ${SECRETS})
POSTGRES_PASSWORD=$(kamal secrets extract POSTGRES_PASSWORD ${SECRETS})
S3_ACCESS_KEY_ID=$(kamal secrets extract S3_ACCESS_KEY_ID ${SECRETS})
S3_SECRET_ACCESS_KEY=$(kamal secrets extract S3_SECRET_ACCESS_KEY ${SECRETS})
```

With colocated accessories, `DATABASE_URL` and `REDIS_URL` point at the Docker network aliases, not localhost:

```
postgresql://reckoning:<password>@reckoning-db:5432/reckoning_production
redis://reckoning-redis:6379/0
```
