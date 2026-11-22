terraform {
  # hashicorp/vault 5.x is built for Terraform/OpenTofu >= 1.11; Atlantis pins
  # 1.13.x (atlantis.yaml), so this floor only bites stale local installs.
  required_version = ">= 1.11"

  required_providers {
    # The stock hashicorp/vault provider drives OpenBao (same HTTP API).
    # openbao/terraform-provider-vault exists but has no releases; do not switch
    # until it publishes to a registry.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}
