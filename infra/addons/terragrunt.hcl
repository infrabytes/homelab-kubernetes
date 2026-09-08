include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

dependencies {
  paths = ["../cluster"]
}

# `dependencies` only guarantees ordering, not readiness: right after cluster
# bootstrap the controlplane reboots into its cluster config, so the API
# endpoint can be momentarily unreachable. Retry the whole apply until it
# accepts connections.
errors {
  retry "cluster_not_ready" {
    retryable_errors = [
      ".*connection refused.*",
      ".*Kubernetes cluster unreachable.*",
      ".*dial tcp .*: connect.*",
      ".*connection reset by peer.*",
      ".*failed to execute.*kubeconfig.*",
      ".*failed to create new session client.*",
      ".*failed to connect.*argocd.*",
      ".*Get \\\"https://.*connection refused.*",
    ]
    max_attempts       = 20
    sleep_interval_sec = 30
  }
}

inputs = local.env.locals.addons
