include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl"))
}

# Serialize applies: in-place node upgrades (cordon+drain -> reboot) must not
# run in parallel: workers would take every Longhorn replica down at once,
# controlplanes would risk etcd quorum. -parallelism=1 applies one resource
# at a time: controlplanes first (module depends_on), then workers one by one.
terraform {
  extra_arguments "serialize_apply" {
    commands  = ["apply"]
    arguments = ["-parallelism=1"]
  }

  # The provider's upgrade drain is capped at 5 minutes and fails the apply when
  # a worker's drain chain (Longhorn PDB teardown, slow pod termination) exceeds
  # it, so drain ahead of the apply where there is no deadline. Nodes stay
  # cordoned when the apply fails afterwards; re-plan and re-apply to resume.
  before_hook "pre_upgrade_drain" {
    commands = ["apply"]
    execute  = ["bash", "${get_parent_terragrunt_dir()}/scripts/pre-drain-talos-upgrade.sh"]
  }
}

inputs = local.env.locals.cluster
