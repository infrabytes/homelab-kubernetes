variable "kubeconfig_path" {
  description = "Path to the cluster kubeconfig, passed from env.hcl."
  type        = string
}

variable "gitops_repo_url" {
  description = "Git (HTTPS) URL of the repo containing the platform/ and apps/ folders ArgoCD syncs."
  type        = string
}

variable "argocd_admin_password" {
  description = "PLAINTEXT ArgoCD admin password used by the argocd provider to authenticate (set on the cluster via the addons unit's initial-admin-secret)."
  type        = string
  sensitive   = true
}

variable "argocd_tf_token" {
  description = "Long-lived API token for the tf-bot service account. Used by the argocd provider once the local admin login is disabled (SSO-only mode); falls back to the admin password while empty (bootstrap)."
  type        = string
  default     = ""
  sensitive   = true
}
