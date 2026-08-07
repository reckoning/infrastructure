terraform {
  required_version = ">= 1.12.0"

  backend "s3" {
    endpoints = {
      s3 = "https://nbg1.your-objectstorage.com"
    }
    bucket = "reckoning-terraform-state"
    key    = "terraform.tfstate"
    region = "nbg1"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.60"
    }

    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = ">= 2.3"
    }

    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }

    onepassword = {
      source  = "1Password/onepassword"
      version = ">= 2.1"
    }
  }
}
