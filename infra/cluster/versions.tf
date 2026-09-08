terraform {
  # talos_machine/talos_cluster (ephemeral drain kubeconfig + write-only
  # attributes) need OpenTofu >= 1.11.
  required_version = ">= 1.11"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.112.0"
    }
    talos = {
      source = "siderolabs/talos"
      # 0.12 adds talos_machine/talos_cluster, which own Talos OS and
      # Kubernetes upgrades (the 0.11 apply-only flow never upgraded the OS).
      # Beta until 0.12.0 stable; pinned exactly, and Renovate bumps the pin
      # once a newer stable release exists (pre-releases are skipped).
      version = "= 0.12.0-beta.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
