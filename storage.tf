# Active Storage bucket. Replaces the retired DigitalOcean Spaces bucket still
# referenced by config/storage.yml in the app repo — see scripts/import-storage.sh.
resource "aws_s3_bucket" "storage" {
  bucket = "${local.prefix}-storage"
}

resource "aws_s3_bucket_cors_configuration" "storage" {
  count  = length(local.env.cors_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.storage.id

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

# Hetzner Object Storage bills a flat monthly fee per bucket, so by default the
# postgres-backup-s3 accessory writes into the storage bucket under a `db/`
# prefix rather than paying for a second bucket.
resource "aws_s3_bucket" "backups" {
  count  = var.separate_backup_bucket ? 1 : 0
  bucket = "${local.prefix}-backups"
}
