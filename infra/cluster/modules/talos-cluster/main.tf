resource "talos_machine_secrets" "this" {}

locals {
  # Per-node config patches, applied when the machine configuration is
  # generated (data.talos_machine_configuration) so each node's rendered
  # configuration is complete before it reaches talos_machine.
  config_patches = {
    for key, node in var.nodes : key => concat(
      [
        templatefile("${path.module}/templates/node-config.yaml.tmpl", {
          hostname     = node.hostname
          install_disk = node.install_disk
          # machine.install.image must match the node's own schematic
          # (extensions), not the static base scheme — otherwise a fresh
          # reinstall would silently drop extensions like Longhorn's
          # iscsi-tools.
          install_img    = node.install_img
          ip_address     = format("%s/%d", node.ipv4_address, node.ipv4_prefix)
          gateway        = node.ipv4_gateway
          dns_servers    = node.dns_servers
          interface_name = node.mac_address != "" ? format("enx%s", lower(replace(node.mac_address, ":", ""))) : "eth0"
          node_labels    = node.node_labels
          node_taints    = node.node_taints
        })
      ],
      # Stream Talos service logs (machined, apid, containerd, kubelet,
      # kernel, ...) as json_lines over TCP to the node's own IP, where the
      # k8s-monitoring Alloy DaemonSet listens (hostNetwork).
      # https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/logging-and-telemetry/logging
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
      # Disable Talos's built-in CNI (Flannel) so Cilium (installed as an
      # inline manifest on controlplane nodes) is the only CNI, and disable
      # kube-proxy: Cilium runs with kubeProxyReplacement=true (required for
      # L2 announcements). All nodes.
      [
        yamlencode({
          cluster = {
            network = {
              cni = { name = "none" }
            }
            proxy = {
              disabled = true
            }
          }
        })
      ],
      # Kubelet serving-cert rotation so kubelets get CA-signed serving certs
      # (no --kubelet-insecure-tls for metrics-server):
      # https://docs.siderolabs.com/kubernetes-guides/monitoring-and-observability/deploy-metrics-server
      [
        yamlencode({
          machine = {
            kubelet = {
              extraArgs = {
                "rotate-server-certificates" = "true"
              }
            }
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
      # swap — no minSize/maxSize) + zswap compressed swap cache, on all nodes.
      # https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/swap
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
      # https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/swap#kubernetes-and-swap
      [
        yamlencode({
          machine = {
            kubelet = {
              extraConfig = {
                memorySwap = {
                  swapBehavior = "LimitedSwap"
                }
              }
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
      # Controlplane-only inline manifests, applied in order:
      #  1. Gateway API CRDs — must exist before the Cilium gateway controller
      #     starts (Cilium 1.20 requires Gateway API v1.6.1 CRDs).
      #  2. Cilium (with kube-proxy replacement, L2 announcements, Gateway API).
      # Identical content on every controlplane (per the Sidero docs).
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
            inlineManifests = [
              { name = "gateway-api-crds", contents = var.gateway_api_inline_manifest },
              { name = "cilium", contents = var.cilium_inline_manifest },
            ]
          }
        })
      ] : []
    )
  }
}

# One rendered machine configuration per node (base config + per-node
# patches). kubernetes_version bakes the component image tags new nodes
# bootstrap with; upgrading Kubernetes on running nodes is owned by
# talos_cluster.
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

# talos_machine replaces the old talos_machine_configuration_apply flow: it
# applies the machine configuration and keeps the running Talos version in
# sync with `image` (= the machine.install.image patch above). When the
# installer image changes, the node is upgraded in place first (pull ->
# install -> cordon+drain -> reboot -> wait for health -> uncordon), and only
# then the new configuration is applied, so the upgraded node accepts the
# new kubelet version instead of the old node rejecting it (the old flow
# never upgraded the OS, so machine configs crept ahead of the running Talos
# and apply eventually failed with "version of Kubernetes ... is too new to
# be used with Talos ...").
# ignore_kubernetes_upgrade_drift keeps the Kubernetes component image tags
# (owned by talos_cluster's upgrade-k8s procedure) out of the config-drift
# hash, so a kubernetes_version bump is applied by talos_cluster with its
# sequencing, not by re-applying configs to all nodes at once.
# Controlplane and worker are separate resources so controlplane nodes are
# always installed and upgraded before workers; workers serialize among
# themselves via `tofu apply -parallelism=1` (see the unit's terragrunt.hcl
# for why).
resource "talos_machine" "controlplane" {
  for_each = { for k, v in var.nodes : k => v if v.role == "controlplane" }

  node                            = each.key
  image                           = each.value.install_img
  machine_configuration           = data.talos_machine_configuration.this[each.key].machine_configuration
  client_configuration            = talos_machine_secrets.this.client_configuration
  kubeconfig_wo                   = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw
  drain_on_upgrade                = true
  ignore_kubernetes_upgrade_drift = true
}

resource "talos_machine" "worker" {
  for_each = { for k, v in var.nodes : k => v if v.role == "worker" }

  depends_on = [talos_machine.controlplane]

  node                            = each.key
  image                           = each.value.install_img
  machine_configuration           = data.talos_machine_configuration.this[each.key].machine_configuration
  client_configuration            = talos_machine_secrets.this.client_configuration
  kubeconfig_wo                   = ephemeral.talos_cluster_kubeconfig.drain.kubeconfig_raw
  drain_on_upgrade                = true
  ignore_kubernetes_upgrade_drift = true
}

locals {
  controlplane_ips      = [for k, v in var.nodes : k if v.role == "controlplane"]
  first_controlplane_ip = local.controlplane_ips[0]
}

# talos_cluster replaces talos_machine_bootstrap: it bootstraps etcd
# (idempotent: AlreadyExists is success) and owns Kubernetes upgrades. A
# kubernetes_version change runs Talos's upgrade-k8s procedure (sequential
# control-plane component upgrades with health gating, kubelet
# node-by-node, CoreDNS/kube-proxy manifests).
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
