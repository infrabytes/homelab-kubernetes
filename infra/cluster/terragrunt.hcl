include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# Serialize applies: talos_machine installs/upgrades nodes in place
# (cordon+drain -> reboot), so parallel worker upgrades would take every
# Longhorn replica down at once (and parallel controlplane upgrades would
# risk etcd quorum on a multi-CP cluster). -parallelism=1 applies one
# resource at a time — controlplane nodes go first (module depends_on),
# then workers one by one. Bootstrap is slower too; fine at this size.
terraform {
  extra_arguments "serialize_apply" {
    commands  = ["apply"]
    arguments = ["-parallelism=1"]
  }
}

inputs = local.env.locals.cluster
