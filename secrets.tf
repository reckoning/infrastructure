provider "onepassword" {}

data "onepassword_vault" "infra" {
  name = "Reckoning"
}

data "onepassword_item" "hetzner" {
  vault = data.onepassword_vault.infra.uuid
  title = terraform.workspace == "live" ? "HCLOUD_LIVE" : "HCLOUD_STAGE"
}

data "onepassword_item" "ssh" {
  vault = data.onepassword_vault.infra.uuid
  title = "SSH Config"
}

# Object Storage credentials are scoped to a Hetzner project, so stage and live
# need their own pair. These are read explicitly rather than from
# AWS_ACCESS_KEY_ID, which the S3 state backend claims — see README.
data "onepassword_item" "object_storage" {
  vault = data.onepassword_vault.infra.uuid
  title = terraform.workspace == "live" ? "HETZNER_S3_LIVE" : "HETZNER_S3_STAGE"
}

data "onepassword_item" "deploy_key" {
  vault = data.onepassword_vault.infra.uuid
  title = terraform.workspace == "live" ? "Deploy Key Live" : "Deploy Key Stage"
}

data "onepassword_item" "appsignal" {
  count = var.enable_appsignal ? 1 : 0
  vault = data.onepassword_vault.infra.uuid
  title = "APPSIGNAL"
}
