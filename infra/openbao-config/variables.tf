variable "bao_address" {
  description = "OpenBao public endpoint (Gateway-terminated, public LE cert), reached from Atlantis on windrunner over the LAN."
  type        = string
}

variable "bao_approle_role_id" {
  description = "AppRole openbao-tf role_id, created once by OIDC login (sso-admin) after self-init."
  type        = string
}

variable "bao_approle_secret_id" {
  description = "AppRole openbao-tf secret_id (long-TTL; rotate via sops when it expires)."
  type        = string
}

variable "tenants" {
  description = "Tenant list, decoded from argocd/tenants/tenants.json (the single tenant source of truth)."
  type = list(object({
    tenant    = string
    namespace = string
    members = list(object({
      identity = string
      user     = optional(string)
    }))
  }))
}

variable "kv_secrets" {
  description = "Consumer secret data (values from SOPS), keyed by secret name. Each entry becomes one kv-v2 record under the shared secret/ mount; tenants use their own mounts and are seeded by the tenant."
  type = map(object({
    mount = optional(string, "secret")
    data  = map(string)
  }))
}
