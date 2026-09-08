provider "proxmox" {
  endpoint = var.proxmox_endpoint

  # Auth: an API token takes precedence; otherwise username/password is used.
  # Empty values are passed as null so the provider falls back to the
  # PROXMOX_VE_API_TOKEN / PROXMOX_VE_USERNAME / PROXMOX_VE_PASSWORD env vars.
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : null
  username  = var.proxmox_username != "" ? var.proxmox_username : null
  password  = var.proxmox_password != "" ? var.proxmox_password : null

  insecure = var.proxmox_insecure
}

provider "talos" {}

# Used only by data.helm_template to render the Cilium chart locally. No
# kubernetes block is needed: helm_template is a ClientOnly dry-run render and
# never contacts a cluster, so it works before the cluster is bootstrapped.
provider "helm" {}
