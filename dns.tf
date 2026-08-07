locals {
  dns_enabled = var.manage_dns && local.env.dns_zone != null

  dns_ip = local.dns_enabled && local.env.web_servers_count > 0 ? (
    local.env.web_servers_count > 1
    ? hcloud_load_balancer.web_load_balancer[0].ipv4
    : hcloud_server.web_server[0].ipv4_address
  ) : null

  dns_fqdns = local.env.dns_zone == null ? [] : [
    for name in local.env.hostnames :
    name == "@" ? local.env.dns_zone : "${name}.${local.env.dns_zone}"
  ]

  current_email = lookup(var.email_config, terraform.workspace, null)
}

# reckoning.me is shared between the stage and live workspaces (stage lives under
# stage.reckoning.me), so exactly one workspace may own the zone resource. The
# other writes rrsets into the same zone by name.
resource "hcloud_zone" "zone" {
  count = local.dns_enabled && terraform.workspace == var.dns_zone_owner_workspace ? 1 : 0
  name  = local.env.dns_zone
  mode  = "primary"
}

resource "hcloud_zone_rrset" "web" {
  for_each = local.dns_enabled && local.env.web_servers_count > 0 ? toset(local.env.hostnames) : toset([])

  zone    = local.env.dns_zone
  type    = "A"
  name    = each.value
  ttl     = 600
  records = [{ value = local.dns_ip }]

  depends_on = [hcloud_zone.zone]
}

# --- Offline placeholder (scaled-to-zero environments) ---
#
# With no web servers there is nothing to point at, so the hostnames resolve to
# GitHub Pages, which serves placeholder/ from this repo. Pages routes by Host
# header using placeholder/CNAME, and only for the single domain named there —
# wildcard hostnames are excluded because Pages cannot serve them.
#
# IPs are GitHub's documented Pages anycast addresses:
# https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site/managing-a-custom-domain-for-your-github-pages-site
locals {
  github_pages_ips = [
    "185.199.108.153",
    "185.199.109.153",
    "185.199.110.153",
    "185.199.111.153",
  ]

  placeholder_hostnames = [
    for name in local.env.hostnames : name if !strcontains(name, "*")
  ]
}

resource "hcloud_zone_rrset" "placeholder" {
  for_each = local.dns_enabled && local.env.web_servers_count == 0 ? toset(local.placeholder_hostnames) : toset([])

  zone    = local.env.dns_zone
  type    = "A"
  name    = each.value
  ttl     = 600
  records = [for ip in local.github_pages_ips : { value = ip }]

  depends_on = [hcloud_zone.zone]
}

# --- Mail ---
# Only rendered once var.email_config carries the records transcribed from the
# existing reckoning.me zone. See docs/dns-migration.md.

resource "hcloud_zone_rrset" "mx" {
  count = local.dns_enabled && try(local.current_email.mx_records, null) != null ? 1 : 0

  zone    = local.env.dns_zone
  type    = "MX"
  name    = "@"
  ttl     = 3600
  records = local.current_email.mx_records

  depends_on = [hcloud_zone.zone]
}

resource "hcloud_zone_rrset" "email_cname" {
  for_each = local.dns_enabled ? try(local.current_email.cnames, {}) : {}

  zone    = local.env.dns_zone
  type    = "CNAME"
  name    = each.key
  ttl     = 600
  records = [{ value = each.value }]

  depends_on = [hcloud_zone.zone]
}

resource "hcloud_zone_rrset" "dkim" {
  for_each = local.dns_enabled ? try(local.current_email.dkim, {}) : {}

  zone    = local.env.dns_zone
  type    = "TXT"
  name    = "${each.key}._domainkey"
  ttl     = 600
  records = [{ value = "\"k=rsa;p=${each.value}\"" }]

  depends_on = [hcloud_zone.zone]
}

resource "hcloud_zone_rrset" "txt" {
  count = local.dns_enabled && try(local.current_email.txt_records, null) != null ? 1 : 0

  zone    = local.env.dns_zone
  type    = "TXT"
  name    = "@"
  ttl     = 600
  records = [for v in local.current_email.txt_records : { value = v }]

  depends_on = [hcloud_zone.zone]
}
