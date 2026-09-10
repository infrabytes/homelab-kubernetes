resource "talos_machine_secrets" "this" {}

locals {
  # Talos 1.14+ generates a multi-document machine config: install, network,
  # kubelet, CNI and kube-proxy settings live in separate documents, and
  # v1alpha1 patches for those fields conflict with them. All patches target
  # the new documents.

  # Per-node config patches, applied at machine-config generation time so each
  # node's rendered configuration is complete before it reaches talos_machine.
  config_patches = {
    for key, node in var.nodes : key => concat(
      [
        templatefile("${path.module}/templates/node-config.yaml.tmpl", {
          hostname       = node.hostname
          # Fall back to /dev/sda (the provider's generate default) so the
          # UnattendedInstallConfig selector is always set.
          install_disk   = node.install_disk == null || node.install_disk == "" ? "/dev/sda" : node.install_disk
          install_img    = node.install_img
          ip_address     = format("%s/%d", node.ipv4_address, node.ipv4_prefix)
          gateway        = node.ipv4_gateway
          dns_servers    = node.dns_servers
          interface_name = node.mac_address != "" ? format("enx%s", lower(replace(node.mac_address, ":", ""))) : "eth0"
          node_labels    = node.node_labels
          node_taints    = node.node_taints
        })
      ],
      # Stream Talos service logs as json_lines over TCP to the node's own IP,
      # where the k8s-monitoring Alloy DaemonSet listens (hostNetwork).
      # https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/logging-and-telemetry/logging
      var.talos_log_enabled ? [
        yamlencode({
          machine = {
            logging = {
              destinations = [
                {
                  endpoint  = "tcp://${node.ipv4_address}:${var.talos_log_port}/"
                  format    = "json_lines"
                  extraTags = { node = node.hostname }
                }
              ]
            }
          }
        })
      ] : [],
      # Disable Talos's built-in CNI (Flannel) and kube-proxy: Cilium (inline
      # manifest on controlplanes) is the only CNI with
      # kubeProxyReplacement=true (required for L2 announcements). Both live
      # in controlplane-only documents; the generated config has neither on
      # workers.
      node.role == "controlplane" ? [
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeFlannelCNIConfig"
          "$patch"   = "delete"
        }),
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeProxyConfig"
          enabled    = false
        })
      ] : [],
      # Kubelet serving-cert rotation so kubelets get CA-signed serving certs
      # (no --kubelet-insecure-tls for metrics-server):
      # https://docs.siderolabs.com/kubernetes-guides/monitoring-and-observability/deploy-metrics-server
      [
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeletConfig"
          extraArgs = {
            "rotate-server-certificates" = "true"
          }
        })
      ],
      # Spegel P2P image mirroring: retain unpacked layers so nodes can serve
      # images to peers.
      # https://docs.siderolabs.com/kubernetes-guides/advanced-guides/spegel
      [
        yamlencode({
          machine = {
            files = [
              {
                path    = "/etc/cri/conf.d/20-customization.part"
                op      = "create"
                content = "[plugins.\"io.containerd.cri.v1.images\"]\n  discard_unpacked_layers = false\n"
              }
            ]
          }
        })
      ],
      # Encrypted swap device on the dedicated scsi2 disk (entire disk is used as
      # swap, no minSize/maxSize) + zswap compressed swap cache, on all nodes.
      # https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/swap
      [
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "SwapVolumeConfig"
          name       = "swap"
          provisioning = {
            diskSelector = {
              match = "'/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2' in disk.symlinks"
            }
            # minSize only: maxSize unset => Talos grows the partition to fill the
            # entire disk (no leftover space). minSize acts as a floor.
            minSize = "3GiB"
          }
          encryption = {
            provider = "luks2"
            keys = [
              {
                # nodeID: key derived from node UUID + partition label. TPM keys
                # require a Secure Boot UKI (pcrpkey in /.extra), which this
                # non-secureboot cluster doesn't have.
                slot   = 0
                nodeID = {}
              }
            ]
          }
        })
      ],
      [
        yamlencode({
          apiVersion      = "v1alpha1"
          kind            = "ZswapConfig"
          maxPoolPercent  = 20
          shrinkerEnabled = true
        })
      ],
      # Let the kubelet use swap:
      # https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/swap#kubernetes-and-swap
      [
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeletConfig"
          config = {
            memorySwap = {
              swapBehavior = "LimitedSwap"
            }
          }
        })
      ],
      # Worker-only Longhorn storage disk: Talos carves the dedicated scsi1
      # disk into a volume mounted at /var/mnt/longhorn (the UserVolumeConfig
      # data path the Longhorn Helm chart uses as its default).
      # https://docs.siderolabs.com/kubernetes-guides/csi/longhorn
      node.role == "worker" ? [
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "UserVolumeConfig"
          name       = "longhorn"
          volumeType = "disk"
          provisioning = {
            diskSelector = {
              match = "'/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1' in disk.symlinks"
            }
          }
        })
      ] : [],
      # Controlplane-only inline manifests, applied in order: Gateway API CRDs
      # (must exist before the Cilium gateway controller starts) then Cilium.
      # Identical content on every controlplane (per the Sidero docs); each
      # manifest is its own KubeInlineManifestConfig document.
      node.role == "controlplane" ? [
        yamlencode({
          cluster = {
            # Expose the etcd metrics endpoint for monitoring scrapes:
            # https://docs.siderolabs.com/kubernetes-guides/monitoring-and-observability/etcd-metrics
            etcd = {
              extraArgs = {
                "listen-metrics-urls" = "http://0.0.0.0:2381"
              }
            }
          }
        }),
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeInlineManifestConfig"
          name       = "gateway-api-crds"
          manifest   = var.gateway_api_inline_manifest
        }),
        yamlencode({
          apiVersion = "v1alpha1"
          kind       = "KubeInlineManifestConfig"
          name       = "cilium"
          manifest   = var.cilium_inline_manifest
        }),
      ] : []
    )
  }
}

# kubernetes_version bakes the component image tags new nodes bootstrap
# with; upgrading Kubernetes on running nodes is owned by talos_cluster.
data "talos_machine_configuration" "this" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = each.value.role == "controlplane" ? "controlplane" : "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  config_patches     = local.config_patches[each.key]
}

# Admin kubeconfig derived straight from the machine secrets (no live call,
# so it exists before bootstrap) for talos_machine's cordon+drain during OS
# upgrades. Ephemeral + write-only: never persisted to state or disk. The
# artifacts/ kubeconfig comes from the talos_cluster_kubeconfig resource below.
ephemeral "talos_cluster_kubeconfig" "drain" {
  cluster_name    = var.cluster_name
  machine_secrets = talos_machine_secrets.this.machine_secrets
  endpoint        = var.cluster_endpoint
}

# Ordering gate: a node's VM must exist before its machine config is applied.
# Referencing module.proxmox_nodes.vm_ids through a resource keeps that edge
# without a module-level depends_on, which deferred the machine/client
# configuration data sources whenever a VM change was pending (unknown
# talosconfig at plan, phantom talos_machine updates on every resize).
resource "terraform_data" "node_vm" {
  for_each = var.vm_ids
  input    = each.value
}

# talos_machine applies the machine config and keeps the running Talos in
# sync with `image`: on an image change it upgrades the OS in place first
# (pull -> install -> cordon+drain -> reboot -> wait -> uncordon), then
# applies the new config, so the upgraded node accepts the new kubelet
# version. ignore_kubernetes_upgrade_drift keeps the Kubernetes component
# image tags (owned by talos_cluster) out of the config-drift hash.
# Controlplane and worker are separate resources so controlplanes always
# install/upgrade before workers; workers serialize via -parallelism=1
# (see terragrunt.hcl).
resource "talos_machine" "controlplane" {
  for_each = { for k, v in var.nodes : k => v if v.role == "controlplane" }

  depends_on = [terraform_data.node_vm]

  node                            = each.key
  image                           = each.value.install_img
  machine_configuration           = data.talos_machine_configuration.this[each.key].machine_configuration
  client_configuration            = talos_machine_secrets.this.client_configuration
  kubeconfig_wo                   = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw
  drain_on_upgrade                = each.value.drain_on_upgrade
  ignore_kubernetes_upgrade_drift = true
}

resource "talos_machine" "worker" {
  for_each = { for k, v in var.nodes : k => v if v.role == "worker" }

  depends_on = [talos_machine.controlplane, terraform_data.node_vm]

  node                            = each.key
  image                           = each.value.install_img
  machine_configuration           = data.talos_machine_configuration.this[each.key].machine_configuration
  client_configuration            = talos_machine_secrets.this.client_configuration
  kubeconfig_wo                   = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw
  drain_on_upgrade                = each.value.drain_on_upgrade
  ignore_kubernetes_upgrade_drift = true
}

locals {
  controlplane_ips      = [for k, v in var.nodes : k if v.role == "controlplane"]
  first_controlplane_ip = local.controlplane_ips[0]
}

# talos_cluster replaces talos_machine_bootstrap: bootstraps etcd
# (idempotent: AlreadyExists is success) and owns Kubernetes upgrades via
# Talos's upgrade-k8s procedure (sequential control-plane upgrades with
# health gating, kubelet node-by-node, CoreDNS/kube-proxy manifests).
resource "talos_cluster" "this" {
  depends_on = [
    talos_machine.controlplane,
    talos_machine.worker,
  ]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_controlplane_ip
  control_plane_nodes  = local.controlplane_ips
  kubernetes_version   = var.kubernetes_version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = keys(var.nodes)
  endpoints            = local.controlplane_ips
}

resource "talos_cluster_kubeconfig" "this" {
  depends_on = [talos_cluster.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.first_controlplane_ip
}
