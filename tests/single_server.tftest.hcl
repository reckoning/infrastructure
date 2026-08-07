mock_provider "hcloud" {}
mock_provider "aws" {}
mock_provider "onepassword" {}

run "create_servers" {
  command = plan

  assert {
    condition     = hcloud_server.web_server[*].name == ["reckoning-default-web"]
    error_message = "Web server name is not correct"
  }

  assert {
    condition     = hcloud_server.accessory_server[*].name == ["reckoning-default-accessories"]
    error_message = "Accessory server name is not correct"
  }

  assert {
    condition     = hcloud_load_balancer.web_load_balancer == []
    error_message = "Load balancer was created for a single web server"
  }

  assert {
    condition     = can(regex("web", data.cloudinit_config.web_server_config[0].part[0].content))
    error_message = "Cloud-init config for the web server is not correct"
  }

  assert {
    condition     = can(regex("accessories", data.cloudinit_config.accessories_config[0].part[0].content))
    error_message = "Cloud-init config for the accessory server is not correct"
  }
}

run "no_dns_by_default" {
  command = plan

  assert {
    condition     = length(hcloud_zone.zone) == 0
    error_message = "DNS zone was created while manage_dns is false"
  }

  assert {
    condition     = length(hcloud_zone_rrset.web) == 0
    error_message = "DNS records were created while manage_dns is false"
  }
}

run "buckets" {
  command = plan

  assert {
    condition     = aws_s3_bucket.storage[0].bucket == "reckoning-default-storage"
    error_message = "Storage bucket name is not correct"
  }

  assert {
    condition     = aws_s3_bucket.backups[0].bucket == "reckoning-default-backups"
    error_message = "Backups bucket name is not correct"
  }
}

run "backups_share_the_storage_bucket_when_disabled" {
  command = plan

  variables {
    separate_backup_bucket = false
  }

  assert {
    condition     = aws_s3_bucket.backups == []
    error_message = "A separate backups bucket was created while disabled"
  }

  assert {
    condition     = output.backups_bucket == "reckoning-default-storage" && output.backups_prefix == "db"
    error_message = "Backups should fall back to the storage bucket under a db/ prefix"
  }
}

run "scaled_to_zero_provisions_nothing" {
  command = plan

  variables {
    env_config = {
      default = {
        server_type       = "cx23"
        web_servers_count = 0
        accessories_count = 0
        dns_zone          = null
        hostnames         = []
        cors_origins      = []
        object_storage    = false
      }
    }
  }

  assert {
    condition     = aws_s3_bucket.storage == []
    error_message = "A storage bucket was created for a scaled-to-zero environment"
  }

  assert {
    condition     = aws_s3_bucket.backups == []
    error_message = "A backups bucket was created for a scaled-to-zero environment"
  }

  assert {
    condition     = hcloud_server.web_server == []
    error_message = "Servers were created for a scaled-to-zero environment"
  }
}

run "scaled_to_zero_serves_the_placeholder" {
  command = plan

  variables {
    manage_dns = true
    env_config = {
      default = {
        server_type       = "cx23"
        web_servers_count = 0
        accessories_count = 0
        dns_zone          = "reckoning.me"
        hostnames         = ["stage", "*.stage"]
        cors_origins      = []
        object_storage    = false
      }
    }
  }

  assert {
    condition     = length(hcloud_zone_rrset.web) == 0
    error_message = "Web A records were created for an environment with no servers"
  }

  # The wildcard is excluded: GitHub Pages routes by Host header and cannot
  # serve a wildcard subdomain.
  assert {
    condition     = keys(hcloud_zone_rrset.placeholder) == ["stage"]
    error_message = "Placeholder records should cover the non-wildcard hostnames only"
  }

  assert {
    condition     = length(hcloud_zone_rrset.placeholder["stage"].records) == 4
    error_message = "Placeholder should point at all four GitHub Pages addresses"
  }
}

run "running_environment_has_no_placeholder" {
  command = plan

  variables {
    manage_dns = true
    env_config = {
      default = {
        server_type       = "cx23"
        web_servers_count = 1
        accessories_count = 0
        dns_zone          = "reckoning.me"
        hostnames         = ["stage"]
        cors_origins      = []
        object_storage    = false
      }
    }
  }

  assert {
    condition     = length(hcloud_zone_rrset.placeholder) == 0
    error_message = "Placeholder records were created while servers exist"
  }

  assert {
    condition     = length(hcloud_zone_rrset.web) == 1
    error_message = "Web A record missing for a running environment"
  }
}

# Downscaling live must keep the domain usable: apex and www fall back to the
# placeholder, and mail keeps working because MX/TXT do not depend on servers.
run "downscaled_live_keeps_mail_and_serves_placeholder" {
  command = plan

  variables {
    manage_dns = true
    env_config = {
      default = {
        server_type       = "cx23"
        web_servers_count = 0
        accessories_count = 0
        dns_zone          = "reckoning.me"
        hostnames         = ["@", "www", "*"]
        cors_origins      = []
        object_storage    = false
      }
    }
    email_config = {
      default = {
        mx_records  = [{ value = "1 smtp.google.com." }]
        cnames      = {}
        dkim        = {}
        txt_records = ["\"google-site-verification=test\""]
      }
    }
  }

  assert {
    condition     = length(hcloud_zone_rrset.web) == 0
    error_message = "Web A records survived a downscale"
  }

  # The wildcard is dropped on purpose: GitHub Pages routes by Host header and
  # cannot serve arbitrary subdomains, so a record pointing there would lie.
  assert {
    condition     = toset(keys(hcloud_zone_rrset.placeholder)) == toset(["@", "www"])
    error_message = "Placeholder should cover apex and www, and exclude the wildcard"
  }

  assert {
    condition     = length(hcloud_zone_rrset.mx) == 1
    error_message = "MX record was dropped when the servers went away — mail would break"
  }

  assert {
    condition     = length(hcloud_zone_rrset.txt) == 1
    error_message = "Domain-verification TXT was dropped on downscale"
  }
}
