locals {
  talos_factory_url = "https://factory.talos.dev"

  # ISO artifact base name; the Image Factory URL uses this exact filename:
  #   .../image/<schematic_id>/<version>/<image_name>.iso
  talos_iso_name = var.talos_iso_name != "" ? var.talos_iso_name : "metal-${var.talos_arch}"

  talos_system_extensions = var.enable_qemu_guest_agent ? concat(var.talos_system_extensions, ["siderolabs/qemu-guest-agent"]) : var.talos_system_extensions

  proxmox_nodes = {
    for k, v in var.nodes : k => {
      proxmox_node       = v.proxmox_node
      hostname           = v.hostname
      role               = v.role
      vm_id              = v.vm_id
      cores              = v.cores
      memory             = v.memory
      disk_size          = v.disk_size
      longhorn_disk_size = v.longhorn_disk_size
      swap_disk_size     = v.swap_disk_size
      datastore_id       = coalesce(v.datastore_id, var.proxmox_disk_datastore)
      cpu_type           = v.cpu_type
      mac_address        = v.mac_address
      iso_filename       = "talos-${v.hostname}-${substr(talos_image_factory_schematic.node[k].id, 0, 12)}-${var.talos_version}.iso"
      iso_url            = "${local.talos_factory_url}/image/${talos_image_factory_schematic.node[k].id}/${var.talos_version}/${local.talos_iso_name}.iso"
    }
  }

  talos_cluster_nodes = {
    for k, v in var.nodes : k => {
      role         = v.role
      hostname     = v.hostname
      install_disk = v.install_disk
      # The installer image must match the node's own schematic (extensions),
      # not the static base scheme — otherwise a fresh reinstall would silently
      # drop extensions like Longhorn's iscsi-tools.
      install_img  = "factory.talos.dev/installer/${talos_image_factory_schematic.node[k].id}:${var.talos_version}"
      ipv4_address = v.ipv4_address
      ipv4_prefix  = v.ipv4_prefix
      ipv4_gateway = v.ipv4_gateway
      dns_servers  = v.dns_servers
      mac_address  = v.mac_address
      node_labels  = v.node_labels
      node_taints  = v.node_taints
      # Single controlplane: no drain (nothing to evict, and a drain can
      # block the upgrade when the cluster is degraded). Workers drain for
      # graceful pod eviction (Longhorn safety).
      drain_on_upgrade = v.drain_on_upgrade
    }
  }
}
