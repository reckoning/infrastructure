# Active Storage bucket. Replaces the retired DigitalOcean Spaces bucket still
# referenced by config/storage.yml in the app repo — see scripts/import-storage.sh.
#
# Gated on env_config.object_storage so a scaled-to-zero environment doesn't
# carry an unused bucket. Hetzner's Object Storage base price is per account,
# not per bucket, so this is hygiene rather than a cost saving — but the first
# bucket on an account does start the hourly charge.
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

# Separate bucket for the postgres-backup-s3 accessory. Additional buckets are
# free under the per-account base price, so backups are kept out of the bucket
# that carries the app's CORS rules. Set separate_backup_bucket = false to fall
# back to a `db/` prefix in the storage bucket.
resource "aws_s3_bucket" "backups" {
  count  = local.env.object_storage && var.separate_backup_bucket ? 1 : 0
  bucket = "${local.prefix}-backups"
}
