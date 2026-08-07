# Active Storage bucket. Replaces the retired DigitalOcean Spaces bucket still
# referenced by config/storage.yml in the app repo — see scripts/import-storage.sh.
#
# Gated on env_config.object_storage: Hetzner bills a flat monthly fee per
# bucket from the moment it exists, independent of servers or stored bytes, so a
# scaled-to-zero environment must not provision one.
resource "aws_s3_bucket" "storage" {
  count  = local.env.object_storage ? 1 : 0
  bucket = "${local.prefix}-storage"
}

resource "aws_s3_bucket_cors_configuration" "storage" {
  count  = local.env.object_storage && length(local.env.cors_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.storage[0].id

  dynamic "cors_rule" {
    for_each = local.env.cors_origins
    content {
      allowed_headers = ["*"]
      allowed_methods = ["GET", "PUT", "DELETE", "HEAD", "POST"]
      allowed_origins = [cors_rule.value]
      expose_headers  = ["ETag"]
      max_age_seconds = 3600
    }
  }
}

# Second bucket means a second flat fee, so by default the postgres-backup-s3
# accessory writes into the storage bucket under a `db/` prefix instead.
resource "aws_s3_bucket" "backups" {
  count  = local.env.object_storage && var.separate_backup_bucket ? 1 : 0
  bucket = "${local.prefix}-backups"
}
