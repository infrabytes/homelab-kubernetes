variable "nodes" {
  description = "Talos nodes to provision. Key = node IP / talosctl address."
  type = map(object({
    role               = string
    hostname           = string
    proxmox_node       = string
    vm_id              = number
    ipv4_address       = string
    ipv4_prefix        = number
    ipv4_gateway       = string
    dns_servers        = list(string)
    mac_address        = optional(string, "")
    install_disk       = optional(string, "/dev/sda")
    cores              = optional(number, 2)
    memory             = optional(number, 4096)
    disk_size          = optional(number, 40)
    longhorn_disk_size = optional(number, 0)
    swap_disk_size     = optional(number, 0)
    datastore_id       = optional(string, "")
    cpu_type           = optional(string, "host")
    node_labels        = optional(map(string), {})
    node_taints        = optional(list(string), [])
    drain_on_upgrade   = optional(bool, true)
  }))
}
