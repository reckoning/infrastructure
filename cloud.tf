data "hcloud_ssh_key" "by_name" {
  name = data.onepassword_item.ssh.username
}

resource "hcloud_network" "network" {
  name     = "${local.prefix}-private-network"
  ip_range = "10.0.0.0/16"
}

resource "hcloud_network_subnet" "network_subnet" {
  type         = "cloud"
  network_id   = hcloud_network.network.id
  network_zone = "eu-central"
  ip_range     = "10.0.0.0/24"
}

resource "hcloud_server" "web_server" {
  count       = local.env.web_servers_count
  name        = local.env.web_servers_count > 1 ? "${local.prefix}-web-${count.index + 1}" : "${local.prefix}-web"
  image       = var.operating_system
  server_type = local.env.server_type
  location    = var.region
  labels = {
    "ssh"  = "yes"
    "http" = "yes"
    "env"  = terraform.workspace
  }

  user_data = data.cloudinit_config.web_server_config[count.index].rendered

  network {
    network_id = hcloud_network.network.id
    ip         = local.web_server_ips[count.index]
  }

  ssh_keys = [
    data.hcloud_ssh_key.by_name.id
  ]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_server" "accessory_server" {
  count       = local.env.accessories_count
  name        = local.env.accessories_count > 1 ? "${local.prefix}-accessories-${count.index + 1}" : "${local.prefix}-accessories"
  image       = var.operating_system
  server_type = local.env.server_type
  location    = var.region
  labels = {
    "http" = "no"
    "ssh"  = "yes"
    "env"  = terraform.workspace
  }

  user_data = data.cloudinit_config.accessories_config[count.index].rendered

  network {
    network_id = hcloud_network.network.id
    ip         = local.accessories_server_ips[count.index]
  }

  ssh_keys = [
    data.hcloud_ssh_key.by_name.id
  ]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "hcloud_load_balancer" "web_load_balancer" {
  count              = local.env.web_servers_count > 1 ? 1 : 0
  name               = "${local.prefix}-web-load-balancer"
  load_balancer_type = "lb11"
  location           = var.region
}

resource "hcloud_load_balancer_target" "load_balancer_target" {
  count            = local.env.web_servers_count > 1 ? 1 : 0
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.web_load_balancer[count.index].id
  label_selector   = "http=yes,env=${terraform.workspace}"
}

resource "hcloud_managed_certificate" "web_domain" {
  for_each = local.env.web_servers_count > 1 && var.enable_ssl && local.env.dns_zone != null ? toset(local.dns_fqdns) : toset([])
  name     = "${local.prefix}-${replace(each.value, ".", "-")}-cert"

  domain_names = [each.value]
}

resource "hcloud_load_balancer_service" "load_balancer_service_https" {
  count            = local.env.web_servers_count > 1 && var.enable_ssl ? 1 : 0
  load_balancer_id = hcloud_load_balancer.web_load_balancer[0].id
  protocol         = "https"
  listen_port      = 443
  destination_port = 80

  http {
    sticky_sessions = true
    certificates    = [for cert in hcloud_managed_certificate.web_domain : cert.id]
    redirect_http   = true
  }

  health_check {
    protocol = "http"
    port     = 80
    interval = 10
    timeout  = 5
    retries  = 3

    http {
      path         = "/up"
      response     = ""
      tls          = false
      status_codes = var.maintenance ? ["200", "503"] : ["200"]
    }
  }
}

resource "hcloud_load_balancer_service" "load_balancer_service_http" {
  count            = local.env.web_servers_count > 1 && !var.enable_ssl ? 1 : 0
  load_balancer_id = hcloud_load_balancer.web_load_balancer[0].id
  protocol         = "http"

  http {
    sticky_sessions = true
  }

  health_check {
    protocol = "http"
    port     = 80
    interval = 10
    timeout  = 5
    retries  = 3

    http {
      path         = "/up"
      response     = ""
      tls          = false
      status_codes = var.maintenance ? ["200", "503"] : ["200"]
    }
  }
}

resource "hcloud_load_balancer_network" "load_balancer_network" {
  count            = local.env.web_servers_count > 1 ? 1 : 0
  load_balancer_id = hcloud_load_balancer.web_load_balancer[count.index].id
  network_id       = hcloud_network.network.id
  ip               = "10.0.0.254"
}

resource "hcloud_firewall" "block_all_except_ssh" {
  name = "${local.prefix}-allow-ssh"
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  apply_to {
    label_selector = "ssh=yes,env=${terraform.workspace}"
  }
}

resource "hcloud_firewall" "allow_http_https" {
  name = "${local.prefix}-allow-http-https"
  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  apply_to {
    label_selector = "http=yes,env=${terraform.workspace}"
  }
}

resource "hcloud_firewall" "block_all_inbound_traffic" {
  name = "${local.prefix}-block-inbound-traffic"
  # Empty rule set blocks all inbound traffic except what other firewalls allow
  apply_to {
    label_selector = "http=no,env=${terraform.workspace}"
  }
}
