variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster."
  type        = string
}

variable "cluster_endpoint" {
  description = "Kubernetes API server endpoint, e.g. https://10.0.0.10:6443. Should be a stable IP (VIP or first controlplane)."
  type        = string
}

variable "talos_version" {
  description = "Talos Linux version contract for generated machine configs."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes component image versions baked into machine configs."
  type        = string
}

variable "nodes" {
  description = "Talos nodes. Key = node IP / talosctl address."
  type = map(object({
    role         = string
    hostname     = string
    install_disk = string
    install_img  = string
    ipv4_address = string
    ipv4_prefix  = number
    ipv4_gateway = string
    dns_servers  = list(string)
    mac_address  = string
    node_labels  = map(string)
    node_taints  = list(string)
    drain_on_upgrade = optional(bool, true)
  }))
}

variable "vm_ids" {
  description = "Per-node Proxmox VM ids (module.proxmox_nodes.vm_ids). Keys must match `nodes`."
  type        = map(number)
}

variable "artifacts_dir" {
  description = "Directory to write generated talosconfig/kubeconfig artifacts to."
  type        = string
  default     = "artifacts"
}

variable "cilium_inline_manifest" {
  description = "Rendered Cilium manifest (data.helm_template.cilium.manifest) embedded as a Talos inline manifest on controlplane nodes."
  type        = string
  sensitive   = true
}

variable "gateway_api_inline_manifest" {
  description = "Gateway API CRD bundle (pinned release's standard-install.yaml) embedded as a Talos inline manifest on controlplane nodes, listed before the Cilium manifest."
  type        = string
  sensitive   = true
}

variable "talos_log_enabled" {
  description = "Whether to configure machine.logging.destinations so each node streams service logs (json_lines) to its own IP on talos_log_port."
  type        = bool
  default     = false
}

variable "talos_log_port" {
  description = "TCP port each node pushes machine logs to."
  type        = number
  default     = 5140
}
