locals {
  env     = read_terragrunt_config("${get_parent_terragrunt_dir()}/env.hcl")
  secrets = local.env.locals.secrets
}

terraform {
  # Sync gitignored credential artifacts with the bucket so fresh checkouts plan clean; a missing object is a cache miss (plan shows create, apply regenerates + re-uploads).
  before_hook "sync_artifacts_download" {
    commands = ["plan", "apply"]
    execute  = ["${get_parent_terragrunt_dir()}/scripts/sync-artifacts.sh", "download"]
  }

  after_hook "sync_artifacts_upload" {
    commands = ["apply"]
    execute  = ["${get_parent_terragrunt_dir()}/scripts/sync-artifacts.sh", "upload"]
  }
}

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    bucket = "homelab-kubernetes"
    key    = "${path_relative_to_include()}/terraform.tfstate"
    region = "us-east-1" # Required but not used for SeaweedFS

    endpoint = local.secrets.seaweedfs_endpoint

    # S3-compatible settings
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true

    access_key = local.secrets.seaweedfs_access_key
    secret_key = local.secrets.seaweedfs_secret_key
  }

  # Encrypt state at rest (OpenTofu encryption block).
  encryption = {
    key_provider = "pbkdf2"
    passphrase   = local.secrets.state_encryption_passphrase
  }
}
