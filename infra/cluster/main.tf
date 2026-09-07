module "proxmox_nodes" {
  source = "./modules/proxmox-node"

  nodes          = local.proxmox_nodes
  iso_datastore  = var.proxmox_iso_datastore
  network_bridge = var.proxmox_network_bridge
  disk_format    = var.proxmox_disk_format
  disk_ssd       = var.proxmox_disk_ssd
  secure_boot    = var.secure_boot

  enable_guest_agent = var.enable_qemu_guest_agent
}

module "talos_cluster" {
  source = "./modules/talos-cluster"

  depends_on = [
    module.proxmox_nodes,
  ]

  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  nodes              = local.talos_cluster_nodes
  artifacts_dir      = var.artifacts_dir
  talos_log_enabled  = var.talos_log_enabled
  talos_log_port     = var.talos_log_port

  cilium_inline_manifest = data.helm_template.cilium.manifest

  gateway_api_inline_manifest = local.gateway_api_inline_manifest
}
