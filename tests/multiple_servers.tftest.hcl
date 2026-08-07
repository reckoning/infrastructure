mock_provider "hcloud" {}
mock_provider "aws" {}
mock_provider "onepassword" {}

variables {
  env_config = {
    default = {
      server_type       = "cx23"
      web_servers_count = 2
      accessories_count = 2
      dns_zone          = null
      hostnames         = []
      cors_origins      = []
      object_storage    = true
    }
  }
}

run "create_servers" {
  command = plan

  assert {
    condition     = hcloud_server.web_server[*].name == ["reckoning-default-web-1", "reckoning-default-web-2"]
    error_message = "Web server names are not correct"
  }

  assert {
    condition     = hcloud_server.accessory_server[*].name == ["reckoning-default-accessories-1", "reckoning-default-accessories-2"]
    error_message = "Accessory server names are not correct"
  }

  assert {
    condition     = length(hcloud_load_balancer.web_load_balancer) == 1
    error_message = "Load balancer was not created for multiple web servers"
  }

  assert {
    condition     = hcloud_load_balancer_target.load_balancer_target[0].label_selector == "http=yes,env=default"
    error_message = "Load balancer target selector is not scoped to the workspace"
  }
}

run "private_ips_do_not_overlap" {
  command = plan

  assert {
    condition     = length(setintersection(toset(local.web_server_ips), toset(local.accessories_server_ips))) == 0
    error_message = "Web and accessory servers were assigned overlapping private IPs"
  }
}
