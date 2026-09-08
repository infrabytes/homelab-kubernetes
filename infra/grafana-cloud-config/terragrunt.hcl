include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# Order-independent: talks to the Grafana Cloud API, not the cluster, so no
# `dependencies` block needed; runs in parallel in `apply --all`.

inputs = local.env.locals.grafana_cloud
