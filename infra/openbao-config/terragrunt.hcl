include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# No `dependencies {}`: with execution_order_group it blocks the first global
# apply (runatlantis/atlantis#5791). Ordering comes from the group in
# atlantis.yaml. Cold bootstrap: this unit cannot plan until ArgoCD has synced
# the OpenBaoCluster (self-init finished, AppRole created) — re-run
# `atlantis plan` after the cluster is Ready, like the tenant Applications.
errors {
  retry "bao_not_ready" {
    retryable_errors = [
      ".*connection refused.*",
      ".*no such host.*",
      ".*dial tcp .*: connect.*",
      ".*connection reset by peer.*",
    ]
    max_attempts       = 10
    sleep_interval_sec = 30
  }
}

inputs = local.env.locals.openbao_config
