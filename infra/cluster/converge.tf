# Talos applies inline manifests only once: the manifest apply controller skips
# every object already in the bootstrap inventory and backfills the inventory
# for objects that already exist, so chart bumps and values changes never reach
# objects that are already running. These steps close that gap by applying the
# renders to the running cluster after the config apply.
# --field-manager=talos matches the manager Talos itself applies with, so the
# two never fight over field ownership.
resource "local_sensitive_file" "cilium_manifest" {
  content  = data.helm_template.cilium.manifest
  filename = "${var.artifacts_dir}/cilium-manifest.yaml"
}

resource "local_sensitive_file" "gateway_api_crds_manifest" {
  content  = local.gateway_api_inline_manifest
  filename = "${var.artifacts_dir}/gateway-api-crds-manifest.yaml"
}

resource "terraform_data" "inline_manifest_converge" {
  triggers_replace = [
    sha256(data.helm_template.cilium.manifest),
    sha256(local.gateway_api_inline_manifest),
  ]

  provisioner "local-exec" {
    command = join("\n", [
      "kubectl --kubeconfig ${module.talos_cluster.kubeconfig} apply --server-side --field-manager=talos -f ${local_sensitive_file.gateway_api_crds_manifest.filename}",
      "kubectl --kubeconfig ${module.talos_cluster.kubeconfig} apply --server-side --field-manager=talos -f ${local_sensitive_file.cilium_manifest.filename}",
    ])
  }

  depends_on = [module.talos_cluster]
}
