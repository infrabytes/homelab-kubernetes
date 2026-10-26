# 0700/0600: the hooks and every reader of these files run as the same user on the same machine (Atlantis has its own container-local /var/tmp), so no other-reader or other-writer bit is needed.
resource "local_sensitive_file" "talosconfig" {
  content  = data.talos_client_configuration.this.talos_config
  filename = "${var.credentials_dir}/talosconfig"

  directory_permission = "0700"
  file_permission      = "0600"
}

resource "local_sensitive_file" "kubeconfig" {
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename = "${var.credentials_dir}/kubeconfig"

  directory_permission = "0700"
  file_permission      = "0600"
}
