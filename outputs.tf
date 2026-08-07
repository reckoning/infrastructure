output "web_server_ips" {
  description = "Public IPv4 addresses of web servers (comma-separated for Kamal)."
  value       = join(",", hcloud_server.web_server[*].ipv4_address)
}

output "accessory_server_ips" {
  description = "Public IPv4 addresses of accessory servers (comma-separated for Kamal)."
  value       = join(",", hcloud_server.accessory_server[*].ipv4_address)
}

output "accessory_private_ips" {
  description = "Private IPv4 addresses of accessory servers — use these in DATABASE_URL/REDIS_URL so traffic stays on the private network."
  value       = join(",", local.accessories_server_ips)
}

output "ssh_web_server_config" {
  description = "SSH configuration for web servers."
  value = join("\n", [
    for server in hcloud_server.web_server[*] :
    format("Host %s\n  HostName %s\n  User %s", server.name, server.ipv4_address, var.username)
  ])
}

output "ssh_accessory_server_config" {
  description = "SSH configuration for accessory servers, with ProxyJump through the first web server."
  value = length(hcloud_server.web_server) == 0 ? "" : join("\n", [
    for server in hcloud_server.accessory_server[*] :
    format("Host %s\n  HostName %s\n  User %s\n  ProxyJump %s", server.name, server.ipv4_address, var.username, hcloud_server.web_server[0].name)
  ])
}

output "storage_bucket" {
  description = "Active Storage bucket name."
  value       = aws_s3_bucket.storage.bucket
}

output "backups_bucket" {
  description = "Bucket the Postgres backup accessory writes to."
  value       = var.separate_backup_bucket ? one(aws_s3_bucket.backups[*].bucket) : aws_s3_bucket.storage.bucket
}

output "backups_prefix" {
  description = "S3_PREFIX for the postgres-backup-s3 accessory."
  value       = var.separate_backup_bucket ? "" : "db"
}
