locals {
  # Families the Cilium chart dashboards read. The Cilium ServiceMonitors keep
  # only these (see cilium.tf): a blanket cilium_.* would add ~1.9K series that
  # no dashboard references.
  cilium_dashboard_families = [
    "cilium_agent_api_process_time_seconds_count",
    "cilium_agent_api_process_time_seconds_sum",
    "cilium_bpf_map_ops_total",
    "cilium_bpf_map_pressure",
    "cilium_bpf_maps_virtual_memory_max_bytes",
    "cilium_bpf_progs_virtual_memory_max_bytes",
    "cilium_controllers_failing",
    "cilium_controllers_runs_duration_seconds_count",
    "cilium_controllers_runs_duration_seconds_sum",
    "cilium_controllers_runs_total",
    "cilium_datapath_conntrack_dump_resets_total",
    "cilium_datapath_conntrack_gc_entries",
    "cilium_drop_bytes_total",
    "cilium_drop_count_total",
    "cilium_endpoint_regeneration_time_stats_seconds_bucket",
    "cilium_endpoint_regenerations_total",
    "cilium_endpoint_state",
    "cilium_errors_warnings_total",
    "cilium_forward_bytes_total",
    "cilium_forward_count_total",
    "cilium_ip_addresses",
    "cilium_k8s_client_api_calls_total",
    "cilium_k8s_client_api_latency_time_seconds_count",
    "cilium_k8s_client_api_latency_time_seconds_sum",
    "cilium_kubernetes_events_received_total",
    "cilium_kubernetes_events_total",
    "cilium_nodes_all_events_received_total",
    "cilium_nodes_all_num",
    "cilium_operator_ec2_api_duration_seconds_count",
    "cilium_operator_ec2_api_duration_seconds_sum",
    "cilium_operator_ec2_api_rate_limit_duration_seconds_count",
    "cilium_operator_ec2_api_rate_limit_duration_seconds_sum",
    "cilium_operator_ipam_available",
    "cilium_operator_ipam_interface_creation_ops",
    "cilium_operator_ipam_ips",
    "cilium_operator_ipam_nodes",
    "cilium_operator_ipam_resync_total",
    "cilium_operator_process_cpu_seconds_total",
    "cilium_operator_process_resident_memory_bytes",
    "cilium_policy",
    "cilium_policy_change_total",
    "cilium_policy_endpoint_enforcement_status",
    "cilium_policy_implementation_delay_bucket",
    "cilium_policy_incremental_update_duration_bucket",
    "cilium_policy_l7_total",
    "cilium_process_cpu_seconds_total",
    "cilium_process_open_fds",
    "cilium_process_resident_memory_bytes",
    "cilium_process_virtual_memory_bytes",
    "cilium_unreachable_health_endpoints",
    "cilium_unreachable_nodes",
  ]
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
      # not the static base scheme; otherwise a fresh reinstall would silently
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
