terraform {
  required_version = ">= 1.7"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.112.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11.0"
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

  # Optional: point at your state backend (S3/GCS/Azure/SOPS-encrypted local).
  # By default Terraform uses local state in ./terraform.tfstate.
  # backend "s3" {
  #   bucket = "my-homelab-terraform-state"
  #   key    = "homelab-kubernetes/terraform.tfstate"
  #   region = "eu-west-1"
  # }
}
