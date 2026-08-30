locals {
  kc         = yamldecode(file(var.kubeconfig_path))
  kc_context = local.kc["current-context"]
  kc_ctx     = [for c in local.kc.contexts : c if c.name == local.kc_context][0]
  kc_cluster = [for c in local.kc.clusters : c if c.name == local.kc_ctx.context.cluster][0]
  kc_user    = [for u in local.kc.users : u if u.name == local.kc_ctx.context.user][0]
}

provider "argocd" {
  # Prefer the tf-bot service-account token (SSO-only mode disables the local
  # admin login); fall back to the admin password while the token is unset
  # (fresh bootstrap, before the token is generated and stored in SOPS).
  # auth_token must be null (not "") when unused — the provider rejects
  # auth_token combined with password even for an empty token.
  auth_token                  = var.argocd_tf_token != "" ? var.argocd_tf_token : null
  username                    = var.argocd_tf_token != "" ? null : "admin"
  password                    = var.argocd_tf_token != "" ? null : var.argocd_admin_password
  port_forward_with_namespace = "argocd"
  # argocd-server runs plain HTTP (the server.insecure setting), so use
  # plain_text, not insecure/TLS.
  plain_text = true
  kubernetes {
    host                   = local.kc_cluster.cluster.server
    cluster_ca_certificate = base64decode(local.kc_cluster.cluster["certificate-authority-data"])
    client_certificate     = base64decode(local.kc_user.user["client-certificate-data"])
    client_key             = base64decode(local.kc_user.user["client-key-data"])
    config_context         = local.kc_context
  }
}
