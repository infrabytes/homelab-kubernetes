variable "kubeconfig_path" {
  description = "Path to the cluster kubeconfig (written by infra/terraform to artifacts/kubeconfig)."
  type        = string
  default     = "../terraform/artifacts/kubeconfig"
}

variable "gitops_repo_url" {
  description = "Git (HTTPS) URL of the repo containing the platform/ and apps/ folders ArgoCD syncs."
  type        = string
  default     = "https://github.com/infrabytes/homelab-kubernetes"
}

variable "github_pat" {
  description = "GitHub PAT for ArgoCD to clone gitops_repo_url. Leave empty if the repo is public."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (Zone read + DNS edit). Written into cert-manager and external-dns Secrets (DNS-01 / record management)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_admin_password" {
  description = "PLAINTEXT ArgoCD admin password used by the argocd provider to authenticate. Held in the shared SOPS secrets file."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_oidc_client_id" {
  description = "GitHub OAuth app Client ID for ArgoCD SSO (public by design, not a secret)."
  type        = string
  default     = ""
}

variable "github_oidc_client_secret" {
  description = "GitHub OAuth app Client Secret for ArgoCD SSO. Written into argocd-secret as dex.github.clientSecret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_webhook_secret" {
  description = "GitHub webhook shared secret. Written into argocd-secret as webhook.github.secret; the same value must be set on the GitHub repo webhook (Settings -> Webhooks). ArgoCD uses it to verify the X-Hub-Signature-256 of incoming webhook events (argocd.icaninto.space is publicly reachable)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_oidc_org" {
  description = "GitHub org whose members are allowed to log in to ArgoCD (Dex GitHub connector orgs restriction)."
  type        = string
  default     = ""
}

variable "argocd_rbac" {
  description = "ArgoCD RBAC (argocd-rbac-cm): policy.default, OIDC scopes, and policy.csv lines. Configured in env.hcl; users, roles, and project scopes are plain CSV policy lines."
  type = object({
    policy_default = string
    scopes         = string
    policy_csv     = list(string)
  })
  default = null
}

variable "argocd_tf_token" {
  description = "Long-lived API token for the tf-bot service account (generated via `argocd account generate-token`). When set, the local admin account is disabled and the argocd-config provider authenticates with this token; leave empty to keep admin login during bootstrap."
  type        = string
  default     = ""
  sensitive   = true
}

variable "github_runner_token" {
  description = "GitHub PAT (repo scope) for the ARC runner scale set (self-hosted runner used by the Argo CD diff preview workflow). Written into the arc-runner-auth Secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_cloud_prometheus_username" {
  description = "Grafana Cloud Prometheus instance ID (basic-auth username for remote-write)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_cloud_prometheus_token" {
  description = "Grafana Cloud access-policy/API token with the metrics:write scope."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_cloud_loki_username" {
  description = "Grafana Cloud Loki instance ID (basic-auth username for log push)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_cloud_loki_token" {
  description = "Grafana Cloud access-policy/API token with the logs:write scope."
  type        = string
  default     = ""
  sensitive   = true
}
