terraform {
  required_version = ">= 1.7"

  required_providers {
    # The stock hashicorp/vault provider drives OpenBao (same HTTP API).
    # openbao/terraform-provider-vault exists but has no releases; do not switch
    # until it publishes to a registry.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}
