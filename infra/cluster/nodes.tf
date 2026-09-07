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
  default = {
    "10.0.0.10" = {
      role         = "controlplane"
      hostname     = "talos-cp-1"
      proxmox_node = "pve"
      vm_id        = 210
      ipv4_address = "10.0.0.10"
      ipv4_prefix  = 24
      ipv4_gateway = "10.0.0.1"
      dns_servers  = ["10.0.0.1"]
      cores        = 4
      memory       = 8192
      disk_size    = 100
    }
    "10.0.0.11" = {
      role         = "worker"
      hostname     = "talos-worker-1"
      proxmox_node = "pve"
      vm_id        = 211
      ipv4_address = "10.0.0.11"
      ipv4_prefix  = 24
      ipv4_gateway = "10.0.0.1"
      dns_servers  = ["10.0.0.1"]
      cores        = 8
      memory       = 16384
      disk_size    = 200
    }
  }
}
