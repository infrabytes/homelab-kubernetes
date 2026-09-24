# 0777/0666: whichever machine/user (host or Atlantis) last wrote the file must stay readable by the other for refresh, and replaceable on the next apply.
resource "local_sensitive_file" "talosconfig" {
  content  = data.talos_client_configuration.this.talos_config
  filename = "${var.credentials_dir}/talosconfig"

  directory_permission = "0777"
  file_permission      = "0666"
}

resource "local_sensitive_file" "kubeconfig" {
  content  = talos_cluster_kubeconfig.this.kubeconfig_raw
  filename = "${var.credentials_dir}/kubeconfig"

  directory_permission = "0777"
  file_permission      = "0666"
}
