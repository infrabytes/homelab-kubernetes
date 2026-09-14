#!/bin/sh
set -eu
cd ~/homelab/homelab-kubernetes/ansible
export KUBECONFIG_PATH=~/appdata/atlantis/data/artifacts/kubeconfig
exec ~/.local/bin/sops exec-env ../infra/secrets.sops.yaml \
  ~/.local/share/proxmox-maintenance/venv/bin/ansible-playbook \
  -i inventory.yml proxmox-node-updates.yml
