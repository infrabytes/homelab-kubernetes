#!/usr/bin/env bash
# Drains workers not yet on infra/env.hcl's talos_version before the talos_machine apply upgrades them. The provider's cordon+drain is capped at a
# hardcoded 5 minutes, too short here (Longhorn's IM PDB clears only after every volume detaches; NFS teardown stalled loki-0 ~7 min); nodes stay
# cordoned until the provider uncordons them after each reboot. Idempotent; controlplanes skipped; on apply failure, re-plan and re-apply.
set -euo pipefail

# Must match credentials_dir in infra/env.hcl.
export KUBECONFIG="/var/tmp/homelab-artifacts/kubeconfig"

infra_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$(sed -nE 's/^[[:space:]]*talos_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$infra_dir/env.hcl" | head -n1)"
if [ -z "$target" ]; then
  echo "pre-drain: no talos_version found in $infra_dir/env.hcl" >&2
  exit 1
fi

nodes="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.nodeInfo.osImage}{"\n"}{end}')"

stale_nodes=()
while IFS='=' read -r node os_image; do
  running="$(sed -nE 's/.*Talos \((v[0-9.]+)\).*/\1/p' <<<"$os_image")"
  if [ "$running" = "$target" ]; then
    continue
  fi
  labels="$(kubectl get node "$node" -o jsonpath='{.metadata.labels}')"
  if [[ "$labels" == *'node-role.kubernetes.io/control-plane'* ]]; then
    echo "pre-drain: $node runs $running (target $target), controlplane upgrade does not drain, skipping"
    continue
  fi
  echo "pre-drain: $node runs $running, target is $target"
  stale_nodes+=("$node")
done <<<"$nodes"

if [ "${#stale_nodes[@]}" -eq 0 ]; then
  echo "pre-drain: every node already runs Talos $target"
  exit 0
fi

if [ "${PRE_DRAIN_DRY_RUN:-0}" = "1" ]; then
  echo "pre-drain: dry run, would cordon and drain: ${stale_nodes[*]}"
  exit 0
fi

for node in "${stale_nodes[@]}"; do
  kubectl cordon "$node"
  for im_pod in $(kubectl -n longhorn-system get pods --field-selector="spec.nodeName=$node" -o name | grep instance-manager || true); do
    # minAvailable: 1 blocks eviction until Longhorn deletes the PDB itself; safe to delete here, it is recreated once the node is schedulable again.
    kubectl -n longhorn-system delete pdb "${im_pod#pod/}" --ignore-not-found
  done
  echo "pre-drain: draining $node (direct pod deletion, no eviction API)"
  kubectl drain "$node" --ignore-daemonsets --force --delete-emptydir-data --disable-eviction --timeout=30m >/dev/null
  echo "pre-drain: $node drained and cordoned for the upgrade"
done
