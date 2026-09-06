terraform {
  # talos_machine/talos_cluster (ephemeral drain kubeconfig + write-only
  # attributes) need OpenTofu >= 1.11.
  required_version = ">= 1.11"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "= 0.12.0-beta.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
