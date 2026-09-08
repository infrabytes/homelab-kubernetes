include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# Serialize applies: in-place node upgrades (cordon+drain -> reboot) must not
# run in parallel — workers would take every Longhorn replica down at once,
# controlplanes would risk etcd quorum. -parallelism=1 applies one resource
# at a time: controlplanes first (module depends_on), then workers one by one.
terraform {
  extra_arguments "serialize_apply" {
    commands  = ["apply"]
    arguments = ["-parallelism=1"]
  }
}

inputs = local.env.locals.cluster
