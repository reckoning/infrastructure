data "cloudinit_config" "web_server_config" {
  count         = local.env.web_servers_count
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloudinit/base.yml", {
      hostname              = local.env.web_servers_count > 1 ? "web-${count.index + 1}" : "web"
      username              = var.username
      github_username       = var.github_username
      deploy_ssh_public_key = local.deploy_ssh_public_key
    })
  }

  part {
    content_type = "text/cloud-config"
    content      = file("${path.module}/cloudinit/web.yml")
    merge_type   = local.cloudinit_merge_type
  }

  # With no separate accessories box, Postgres and Redis run as Kamal
  # accessories on the web server, so it needs the datastore tuning too.
  dynamic "part" {
    for_each = local.colocated_datastores ? [1] : []
    content {
      content_type = "text/cloud-config"
      content      = file("${path.module}/cloudinit/datastore.yml")
      merge_type   = local.cloudinit_merge_type
    }
  }

  dynamic "part" {
    for_each = var.enable_appsignal ? [1] : []
    content {
      content_type = "text/cloud-config"
      content = templatefile("${path.module}/cloudinit/appsignal.yml", {
        appsignal_push_api_key = local.appsignal_push_api_key
        appsignal_app_name     = "Reckoning"
        appsignal_app_env      = local.appsignal_env
        appsignal_hostname     = local.env.web_servers_count > 1 ? "web-${count.index + 1}" : "web"
      })
      merge_type = local.cloudinit_merge_type
    }
  }
}

data "cloudinit_config" "accessories_config" {
  count         = local.env.accessories_count
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/cloudinit/base.yml", {
      hostname              = local.env.accessories_count > 1 ? "accessories-${count.index + 1}" : "accessories"
      username              = var.username
      github_username       = var.github_username
      deploy_ssh_public_key = local.deploy_ssh_public_key
    })
  }

  part {
    content_type = "text/cloud-config"
    content      = file("${path.module}/cloudinit/datastore.yml")
    merge_type   = local.cloudinit_merge_type
  }

  dynamic "part" {
    for_each = var.enable_appsignal ? [1] : []
    content {
      content_type = "text/cloud-config"
      content = templatefile("${path.module}/cloudinit/appsignal.yml", {
        appsignal_push_api_key = local.appsignal_push_api_key
        appsignal_app_name     = "Reckoning"
        appsignal_app_env      = local.appsignal_env
        appsignal_hostname     = local.env.accessories_count > 1 ? "accessories-${count.index + 1}" : "accessories"
      })
      merge_type = local.cloudinit_merge_type
    }
  }
}
