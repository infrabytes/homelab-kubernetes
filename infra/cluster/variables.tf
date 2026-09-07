## Proxmox connection
variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, e.g. https://pve1.lan:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token, e.g. terraform@pve!token=uuid. Alternatively use PROXMOX_VE_API_TOKEN env var."
  type        = string
  default     = ""
}

variable "proxmox_username" {
  description = "Proxmox username (PAM), e.g. root@pam. Used when api_token is empty."
  type        = string
  default     = ""
}

variable "proxmox_password" {
  description = "Proxmox password for the user above."
  type        = string
  default     = ""
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (self-signed PVE certs)."
  type        = bool
  default     = true
}

## Cluster settings
variable "cluster_name" {
  description = "Name of the Talos/Kubernetes cluster."
  type        = string
  default     = "talos-cluster"
}

variable "cluster_endpoint" {
  description = "Kubernetes API server endpoint, e.g. https://10.0.0.10:6443. Should be a stable IP (VIP or first controlplane)."
  type        = string
  default     = "https://10.0.0.10:6443"
}

## Version pins
variable "talos_version" {
  description = "Talos Linux version to install. Bump here to upgrade."
  type        = string
  default     = "v1.13.8"
}

variable "kubernetes_version" {
  description = "Kubernetes version to install."
  type        = string
  default     = "1.36.0"
}

variable "talos_arch" {
  description = "CPU architecture for the Talos image."
  type        = string
  default     = "amd64"
}

variable "talos_iso_name" {
  description = "Talos ISO artifact name used to build the download URL, e.g. `metal-amd64`, `metal-amd64-secureboot`, `metal-arm64`. Defaults to `metal-<arch>`; must match your Image Factory build (scheme ID alone does not select the boot/secureboot variant)."
  type        = string
  default     = ""
}

## Proxmox storage/network defaults
variable "proxmox_iso_datastore" {
  description = "Datastore that holds the Talos ISOs (e.g. local or a shared CIFS/NFS store)."
  type        = string
  default     = "local"
}

variable "proxmox_disk_datastore" {
  description = "Default datastore for node root disks (e.g. local-lvm or shared)."
  type        = string
  default     = "local-lvm"
}

variable "proxmox_network_bridge" {
  description = "vSwitch/bridge to attach node NICs to."
  type        = string
  default     = "vmbr0"
}

variable "proxmox_disk_format" {
  description = "File format for node root disks. LVM-thin (local-lvm) only supports `raw`; use `qcow2` for directory storage (snapshots)."
  type        = string
  default     = "raw"
}

variable "proxmox_disk_ssd" {
  description = "Enable SSD emulation on node root disks (discard/TRIM passthrough, in-guest SSD identification)."
  type        = bool
  default     = true
}

variable "secure_boot" {
  description = "Enroll manufacturers' Secure Boot keys on the OVMF EFI disks. Required when using a Talos secureboot ISO, otherwise the installed UKI can't boot from disk."
  type        = bool
  default     = false
}

variable "enable_qemu_guest_agent" {
  description = "Enable the QEMU guest agent on the VMs and bake the siderolabs/qemu-guest-agent extension into the node images (see the infra/terraform-isos stack)."
  type        = bool
  default     = false
}

variable "talos_log_enabled" {
  description = "Whether to configure machine.logging.destinations so Talos streams node service logs to the k8s-monitoring Alloy syslog receiver."
  type        = bool
  default     = false
}

variable "talos_log_port" {
  description = "TCP port each Talos node pushes json_lines machine logs to (its own IP on this port)."
  type        = number
  default     = 5140
}

variable "talos_system_extensions" {
  description = "Official Image Factory system extensions baked into every node image (besides the QEMU guest agent, which follows enable_qemu_guest_agent)."
  type        = list(string)
  default     = ["siderolabs/intel-ucode"]
}

variable "talos_maintenance_device" {
  description = "Interface name Talos should configure in maintenance mode via the `ip=` kernel argument. Must be the name the NIC has at initramfs parse time — the kernel default `eth0` (udev renames it to ens18 only later; `ens18`/`enx<mac>` don't exist yet and an empty device picks the wrong link)."
  type        = string
  default     = "eth0"
}

variable "cilium_chart_version" {
  description = "Cilium Helm chart version rendered into the Talos inline manifest (`data.helm_template.cilium`). Bump here to upgrade Cilium."
  type        = string
}

## External access / GitOps
variable "gateway_api_crds_version" {
  description = "Gateway API CRD bundle version embedded as a Talos inline manifest. Must match the version Cilium 1.20 documents as supported (v1.6.1)."
  type        = string
  default     = "v1.6.1"
}

variable "artifacts_dir" {
  description = "Directory to write generated talosconfig/kubeconfig artifacts to. Overridden by Terragrunt to point at the REAL unit dir (Terragrunt runs from a .terragrunt-cache working dir by default)."
  type        = string
}
