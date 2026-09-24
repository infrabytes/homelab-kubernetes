output "kubeconfig" {
  description = "Path to the generated kubeconfig file."
  value       = "${var.credentials_dir}/kubeconfig"
}

output "talosconfig" {
  description = "Path to the generated talosctl config file."
  value       = "${var.credentials_dir}/talosconfig"
}

output "first_controlplane_ip" {
  description = "IP of the first controlplane node (bootstrap target)."
  value       = local.first_controlplane_ip
}

output "talos_machine_secrets" {
  description = "Cluster machine secrets (back these up)."
  value       = talos_machine_secrets.this.machine_secrets
  sensitive   = true
}

output "kubernetes_ca_certificate" {
  description = "Kubernetes API server CA certificate (base64-encoded PEM, as the talos provider delivers it), from the generated kubeconfig. The cluster unit decodes it to PEM for the viewer-kubeconfig unit."
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate
  sensitive   = true
}

output "kubernetes_host" {
  description = "Kubernetes API server endpoint (https://host:6443), from the generated kubeconfig. Used by the viewer-kubeconfig unit to assemble the viewer kubeconfig."
  value       = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
}
