# Viewer kubeconfig: mints a client certificate for the `viewer@talos-cluster`
# user via the standard Kubernetes CSR API (kube-controller-manager signs it
# with the cluster-signing cert/key - no CA key extraction needed) and
# assembles a standalone kubeconfig. The RBAC role for that user lives in
# platform/cluster-viewer/rbac.yaml (ArgoCD-managed).

resource "tls_private_key" "viewer" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# CN only, no organizations: the user gets no groups, so only the
# cluster-viewer ClusterRoleBinding applies.
resource "tls_cert_request" "viewer" {
  private_key_pem = tls_private_key.viewer.private_key_pem

  subject {
    common_name = var.user_name
  }
}

resource "kubernetes_certificate_signing_request_v1" "viewer" {
  metadata {
    name = "cluster-viewer-tls"
  }

  spec {
    signer_name = "kubernetes.io/kube-apiserver-client"
    usages      = ["client auth"]
    request     = tls_cert_request.viewer.cert_request_pem
  }

  # Approved by the cluster admin (this unit's kubernetes provider uses the
  # admin kubeconfig); kube-controller-manager issues the cert.
  auto_approve = true
}

resource "local_sensitive_file" "viewer_kubeconfig" {
  content = templatefile("${path.module}/templates/kubeconfig.tftpl", {
    cluster_name           = var.cluster_name
    context_name           = var.user_name
    user_name              = var.user_name
    server                 = var.kubernetes_host
    ca_certificate_b64     = base64encode(var.kubernetes_ca_certificate)
    client_certificate_b64 = base64encode(kubernetes_certificate_signing_request_v1.viewer.certificate)
    client_key_b64         = base64encode(tls_private_key.viewer.private_key_pem)
  })
  filename = "${var.artifacts_dir}/viewer-kubeconfig"

  directory_permission = "0777"
  file_permission      = "0666"

  # A standalone `terragrunt apply` does NOT re-apply the cluster dependency
  # (it only reads its state), so if that state predates the new outputs the
  # try() fallback in terragrunt.hcl would silently supply empty values and a
  # broken kubeconfig would be written. Fail loudly instead.
  lifecycle {
    precondition {
      condition     = var.kubernetes_ca_certificate != "" && var.kubernetes_host != ""
      error_message = "kubernetes_ca_certificate/kubernetes_host are empty: apply the cluster unit first (it must have been applied with the new outputs, e.g. via terragrunt apply --all)."
    }
  }
}
