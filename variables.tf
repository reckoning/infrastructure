variable "region" {
  description = "The Hetzner Cloud region where resources will be provisioned. See https://docs.hetzner.com/cloud/general/locations for available locations."
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "ash", "hil", "sin"], var.region)
    error_message = "The region must be one of fsn1, nbg1, hel1, ash, hil, or sin."
  }
}

variable "operating_system" {
  description = "The operating system image to use for the servers."
  type        = string
  default     = "ubuntu-24.04"
}

variable "env_config" {
  description = "Per-environment configuration, keyed by workspace name."
  type = map(object({
    server_type       = string
    web_servers_count = number
    accessories_count = number
    dns_zone          = string
    hostnames         = list(string)
    cors_origins      = list(string)
  }))
  default = {
    default = {
      server_type       = "cx23"
      web_servers_count = 1
      accessories_count = 1
      dns_zone          = null
      hostnames         = []
      cors_origins      = ["http://reckoning.test", "http://*.reckoning.test"]
    }
    # Scaled to zero — spin stage up on demand by bumping web_servers_count,
    # apply, then scale back down. Idle stage costs nothing this way.
    stage = {
      server_type       = "cx23"
      web_servers_count = 0
      accessories_count = 0
      dns_zone          = "reckoning.me"
      hostnames         = ["stage", "*.stage"]
      cors_origins      = ["https://stage.reckoning.me"]
    }
    # Single node: Postgres and Redis run as Kamal accessories on the web server
    # rather than a separate accessories box. Halves the monthly bill; see the
    # cost ladder in README.md before changing this.
    live = {
      server_type       = "cx23"
      web_servers_count = 1
      accessories_count = 0
      dns_zone          = "reckoning.me"
      hostnames         = ["@", "www", "*"]
      cors_origins      = ["https://reckoning.me", "https://*.reckoning.me"]
    }
  }
}

variable "dns_zone_owner_workspace" {
  description = "Workspace that owns the hcloud_zone resource. stage and live share the reckoning.me zone, so only one workspace may manage the zone itself; the other only writes rrsets into it."
  type        = string
  default     = "live"
}

variable "manage_dns" {
  description = "Whether to create DNS records. Defaults to false: reckoning.me is still served by its existing nameservers, and pointing records at empty servers would take the live site down. Flip to true per workspace once the servers are provisioned and the zone has been imported."
  type        = bool
  default     = false
}

variable "enable_ssl" {
  description = "Whether to enable SSL on the load balancer. Only relevant when web_servers_count > 1 — with a single web server, kamal-proxy terminates TLS itself. Requires DNS to point at the LB first (managed certs use HTTP-01 validation)."
  type        = bool
  default     = true
}

variable "maintenance" {
  description = "Enable maintenance mode. Relaxes LB health checks to accept 503 responses so kamal-proxy can serve a maintenance page."
  type        = bool
  default     = false
}

variable "separate_backup_bucket" {
  description = "Provision a dedicated bucket for Postgres backups. Hetzner Object Storage charges a flat monthly fee per bucket, so the default keeps backups in the storage bucket under a db/ prefix."
  type        = bool
  default     = false
}

variable "enable_appsignal" {
  description = "Install the AppSignal host agent via cloud-init. Requires an APPSIGNAL item in the 1Password vault."
  type        = bool
  default     = true
}

variable "username" {
  description = "The username for SSH access to the servers."
  type        = string
  default     = "kamal"
}

variable "github_username" {
  description = "The GitHub username whose public SSH keys are imported for server access."
  type        = string
  default     = "mortik"
}

variable "email_config" {
  description = "Per-workspace mail DNS. Left null until the records from the current reckoning.me zone have been transcribed — inventing MX/DKIM values would silently break mail delivery."
  type = map(object({
    mx_records  = list(object({ value = string }))
    cnames      = map(string)
    dkim        = map(string)
    txt_records = list(string)
  }))
  default = {}
}
