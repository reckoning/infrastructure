provider "hcloud" {
  token = data.onepassword_item.hetzner.credential
}

provider "aws" {
  region                      = "fsn1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = "https://fsn1.your-objectstorage.com"
  }
}
