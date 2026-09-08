resource "proxmox_download_file" "node_iso" {
  for_each     = var.nodes
  content_type = "iso"
  datastore_id = var.iso_datastore
  node_name    = each.value.proxmox_node
  file_name    = each.value.iso_filename
  url          = each.value.iso_url
  overwrite    = true
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name        = each.value.hostname
  description = "Talos ${each.value.role} node ${each.key} (managed by Terraform)"
  tags        = ["talos", "kubernetes", each.value.role, "terraform"]

  node_name = each.value.proxmox_node
  vm_id     = each.value.vm_id

  # Talos-on-Proxmox baseline (see Sidero docs):
  # BIOS ovmf (UEFI), machine q35, CPU host, VirtIO SCSI, 4MB EFI disk.
  machine = "q35"
  bios    = "ovmf"
  on_boot = true
  started = true

  cpu {
    cores = each.value.cores
    type  = each.value.cpu_type
  }

  memory {
    dedicated = each.value.memory
    # ballooning not supported by Talos
  }

  disk {
    datastore_id = each.value.datastore_id
    interface    = "scsi0"
    size         = each.value.disk_size
    file_format  = var.disk_format
    cache        = "writethrough"
    discard      = "on"
    ssd          = var.disk_ssd
  }

  # Dedicated Longhorn storage disk (per-node, on local-lvm thin pool).
  dynamic "disk" {
    for_each = each.value.longhorn_disk_size > 0 ? [each.value] : []

    content {
      datastore_id = disk.value.datastore_id
      interface    = "scsi1"
      size         = disk.value.longhorn_disk_size
      file_format  = var.disk_format
      cache        = "writethrough"
      discard      = "on"
      ssd          = var.disk_ssd
    }
  }

  # Dedicated swap disk (per-node, on local-lvm thin pool). Talos provisions
  # the entire disk as an encrypted swap volume (SwapVolumeConfig).
  dynamic "disk" {
    for_each = each.value.swap_disk_size > 0 ? [each.value] : []

    content {
      datastore_id = disk.value.datastore_id
      interface    = "scsi2"
      size         = disk.value.swap_disk_size
      file_format  = var.disk_format
      cache        = "writethrough"
      discard      = "on"
      ssd          = var.disk_ssd
    }
  }

  efi_disk {
    datastore_id      = each.value.datastore_id
    type              = "4m"
    pre_enrolled_keys = var.secure_boot
  }

  cdrom {
    interface = "ide2"
    file_id   = "${var.iso_datastore}:iso/${each.value.iso_filename}"
  }

  boot_order = ["scsi0", "ide2"]

  network_device {
    bridge      = var.network_bridge
    mac_address = each.value.mac_address != "" ? each.value.mac_address : null
  }

  serial_device {}

  rng {
    source = "/dev/urandom"
  }

  tpm_state {
    datastore_id = each.value.datastore_id
    version      = "v2.0"
  }

  agent {
    enabled = var.enable_guest_agent
    wait_for_ip {
      disabled = true
    }
  }
  stop_on_destroy = true

  depends_on = [proxmox_download_file.node_iso]
}
