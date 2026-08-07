locals {
  env    = var.env_config[terraform.workspace]
  prefix = "reckoning-${terraform.workspace}"

  deploy_ssh_public_key = data.onepassword_item.deploy_key.public_key

  colocated_datastores = local.env.accessories_count == 0

  cloudinit_merge_type = "list(append)+dict(recurse_array)+str()"

  appsignal_push_api_key = var.enable_appsignal ? one(data.onepassword_item.appsignal[*].credential) : ""
  appsignal_env          = terraform.workspace == "live" ? "production" : "staging"

  web_server_ips = [
    for i in range(local.env.web_servers_count) :
    "10.0.0.${i + 2}"
  ]
  accessories_server_ips = [
    for i in range(local.env.accessories_count) :
    "10.0.0.${i + local.env.web_servers_count + 2}"
  ]
}
