terraform {
  # talos_machine/talos_cluster (ephemeral drain kubeconfig + write-only
  # attributes) need OpenTofu >= 1.11.
  required_version = ">= 1.11"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.123.0"
    }
    talos = {
      source = "siderolabs/talos"
      # 0.12 adds talos_machine/talos_cluster, which own Talos OS and
      # Kubernetes upgrades (the 0.11 apply-only flow never upgraded the OS).
      # 0.13.0-alpha adds drain_timeout and uncordons a node whose drain
      # failed (0.12.0 left it SchedulingDisabled forever, #718). Pinned
      # exactly; Renovate skips pre-releases, so bump manually and go back
      # to a stable pin once 0.13.0 ships.
      version = "0.13.0-alpha.3"
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
