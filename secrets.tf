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

# Object Storage credentials, read explicitly rather than from AWS_ACCESS_KEY_ID
# which the S3 state backend claims — see README.
#
# The access key goes in the item's top-level `username` field and the secret in
# `credential`, NOT in custom fields: the provider only exposes the top-level
# ones as attributes. (The Fleetyards vault's HETZNER_S3 item uses custom
# `access_key_id`/`secret_access_key` fields, which would read back empty here.)
#
# Only read when the environment actually has buckets, so a workspace with
# object_storage = false needs no Object Storage credentials at all. These are
# project-scoped: if stage ever enables object storage, it needs its own item
# for the reckoning-stage project rather than reusing this one.
data "onepassword_item" "object_storage" {
  count = local.env.object_storage ? 1 : 0
  vault = data.onepassword_vault.infra.uuid
  title = "HETZNER_S3"
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
