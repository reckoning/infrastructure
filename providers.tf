provider "hcloud" {
  token = data.onepassword_item.hetzner.credential
}

provider "aws" {
  region     = "nbg1"
  access_key = one(data.onepassword_item.object_storage[*].username)
  secret_key = one(data.onepassword_item.object_storage[*].credential)

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = "https://nbg1.your-objectstorage.com"
  }
}
