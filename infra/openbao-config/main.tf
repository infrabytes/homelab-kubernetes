# Everything inside OpenBao that the OpenBaoCluster self-init does not own:
# policies, Kubernetes-auth and OIDC roles, kv-v2 mounts and secret data.
# Self-init owns the auth-mount configuration itself (oidc discovery/creds,
# kubernetes host) — TF only writes resources *under* those mounts, so a
# fresh cluster needs no imports.
#
# Idempotency vs. self-init: self-init created the `openbao-admin` policy and
# the `sso-admin`/`sso-user` roles; TF does not re-manage those.

provider "vault" {
  address = var.bao_address

  auth_login {
    path = "auth/approle/login"

    parameters = {
      role_id   = var.bao_approle_role_id
      secret_id = var.bao_approle_secret_id
    }
  }
}

locals {
  # OIDC roles register the LAN, tailnet and CLI redirect URIs (verbatim from
  # the retired postStart script).
  oidc_redirect_uris = [
    "https://bao.icaninto.space/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]

  # Platform consumers: namespace → SecretStore SA → read-scoped path.
  consumers = {
    arc-runners           = { sa = "arc-runners-eso", path = "arc-runner-auth" }
    tailscale             = { sa = "tailscale-eso", path = "tailscale-operator" }
    external-secrets-demo = { sa = "eso-demo", path = "demo" }
    authentik             = { sa = "authentik-eso", path = "authentik" }
    velero                = { sa = "velero-eso", path = "velero" }
    alert-triage          = { sa = "alert-triage-eso", path = "alert-triage" }
    memory-rightsize      = { sa = "memory-rightsize-eso", path = "memory-rightsize" }
    factory               = { sa = "factory-env", path = "factory" }
  }
}

# ---------------------------------------------------------------------------
# Policies
# ---------------------------------------------------------------------------

resource "vault_policy" "consumer_eso" {
  for_each = local.consumers
  name     = "eso-${each.key}"

  # Read-only on one secret path under the shared mount, plus the sys/mounts
  # read ESO's store validation (mount type/version check) needs.
  policy = <<-EOT
    path "secret/data/${each.value.path}" {
      capabilities = ["read", "list"]
    }
    path "secret/metadata/${each.value.path}" {
      capabilities = ["read", "list"]
    }
    path "sys/mounts/secret" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "tenant" {
  for_each = { for t in var.tenants : t.tenant => t }
  name     = "${each.key}-tenant"

  # Full control of the tenant's own mount (verbatim from the retired postStart).
  policy = <<-EOT
    path "${each.key}/data/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "${each.key}/metadata" {
      capabilities = ["list"]
    }
    path "${each.key}/metadata/*" {
      capabilities = ["read", "list", "delete"]
    }
    path "${each.key}/delete/*" {
      capabilities = ["update"]
    }
    path "${each.key}/undelete/*" {
      capabilities = ["update"]
    }
    path "${each.key}/destroy/*" {
      capabilities = ["update"]
    }
    path "sys/mounts/${each.key}" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "tenant_eso" {
  for_each = { for t in var.tenants : t.tenant => t }
  name     = "eso-${each.key}"

  policy = <<-EOT
    path "${each.key}/data/*" {
      capabilities = ["read", "list"]
    }
    path "${each.key}/metadata/*" {
      capabilities = ["read", "list"]
    }
    path "sys/mounts/${each.key}" {
      capabilities = ["read"]
    }
  EOT
}

# ---------------------------------------------------------------------------
# kv-v2 mounts: the shared platform mount + one per tenant
# ---------------------------------------------------------------------------

resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "Shared platform secrets (read by ESO via per-namespace roles)"
}

resource "vault_mount" "tenant" {
  for_each    = { for t in var.tenants : t.tenant => t }
  path        = each.key
  type        = "kv"
  options     = { version = "2" }
  description = "Tenant mount for ${each.key}"
}

# ---------------------------------------------------------------------------
# Secret data (values from SOPS)
# ---------------------------------------------------------------------------

resource "vault_kv_secret_v2" "consumer" {
  for_each  = var.kv_secrets
  mount     = each.value.mount == "secret" ? vault_mount.secret.path : vault_mount.tenant[each.value.mount].path
  name      = each.key
  data_json = jsonencode(each.value.data)
}

# ---------------------------------------------------------------------------
# Kubernetes-auth roles (ESO consumers + tenant stores)
# ---------------------------------------------------------------------------

resource "vault_kubernetes_auth_backend_role" "consumer_eso" {
  for_each                         = local.consumers
  backend                          = "kubernetes"
  role_name                        = "eso-${each.key}"
  bound_service_account_names      = [each.value.sa]
  bound_service_account_namespaces = [each.key]
  token_policies                   = [vault_policy.consumer_eso[each.key].name]
  token_ttl                        = 3600
}

resource "vault_kubernetes_auth_backend_role" "tenant_eso" {
  for_each                         = { for t in var.tenants : t.tenant => t }
  backend                          = "kubernetes"
  role_name                        = "eso-${each.key}"
  bound_service_account_names      = ["${each.key}-eso"]
  bound_service_account_namespaces = [each.value.namespace]
  token_policies                   = [vault_policy.tenant_eso[each.key].name]
  token_ttl                        = 3600
}

# Factory's app-secret store: the factory-server pod writes per-session
# (role factory-app-writer), ESO's ClusterSecretStore reads via
# eso-factory-apps. Ported from the retired postStart script (#654/#658).
resource "vault_mount" "factory_apps" {
  path        = "factory-apps"
  type        = "kv"
  options     = { version = "2" }
  description = "Factory-written app secrets, read by the openbao-factory-apps ClusterSecretStore"
}

resource "vault_policy" "factory_app_writer" {
  name = "factory-app-writer"

  policy = <<-EOT
    path "factory-apps/data/*" {
      capabilities = ["create", "update", "read", "delete", "patch"]
    }
    path "factory-apps/metadata/*" {
      capabilities = ["list", "read", "delete"]
    }
    path "factory-apps/metadata" {
      capabilities = ["list"]
    }
    # ESO store validation reads the mount config; bao kv resolves
    # the mount type through it too.
    path "sys/mounts/factory-apps" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_policy" "eso_factory_apps" {
  name = "eso-factory-apps"

  policy = <<-EOT
    path "factory-apps/data/*" {
      capabilities = ["read"]
    }
    path "factory-apps/metadata/*" {
      capabilities = ["read", "list"]
    }
    path "factory-apps/metadata" {
      capabilities = ["list"]
    }
    # ESO's store validation GETs sys/mounts/<mount>; without read
    # the ClusterSecretStore stays 'unable to validate store'.
    path "sys/mounts/factory-apps" {
      capabilities = ["read"]
    }
  EOT
}

# Break-glass admin path: exec into a pod and log in with its own SA token
# (kubectl exec -n openbao openbao-0 -- bao login -method=kubernetes
# role=openbao-admin). This is what the old postStart used; it keeps an
# authenticated admin session available even when the gateway or Authentik
# are down. The role existed pre-cutover; the TF create is the first write
# after it (self-init does not manage kubernetes-auth roles).
resource "vault_kubernetes_auth_backend_role" "openbao_admin" {
  backend                          = "kubernetes"
  role_name                        = "openbao-admin"
  bound_service_account_names      = ["openbao"]
  bound_service_account_namespaces = ["openbao"]
  token_policies                   = ["openbao-admin"]
  token_ttl                        = 3600
}

resource "vault_kubernetes_auth_backend_role" "factory_app_writer" {
  backend                          = "kubernetes"
  role_name                        = "factory-app-writer"
  bound_service_account_names      = ["factory-server"]
  bound_service_account_namespaces = ["factory"]
  token_policies                   = [vault_policy.factory_app_writer.name]
  token_ttl                        = 3600
}

resource "vault_kubernetes_auth_backend_role" "eso_factory_apps" {
  backend                          = "kubernetes"
  role_name                        = "eso-factory-apps"
  bound_service_account_names      = ["factory-apps-eso"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.eso_factory_apps.name]
  token_ttl                        = 3600
}

# ---------------------------------------------------------------------------
# OIDC roles for tenant SSO (one per tenant with GitHub logins)
# ---------------------------------------------------------------------------

# One role per tenant whose members carry at least one GitHub login; a tenant
# without logins gets no role (mirrors the old postStart delete). The logins
# come from tenants.json `members[].user` and bind the Authentik username
# (`preferred_username`, the same string as the GitHub login).
locals {
  tenant_sso = {
    for t in var.tenants : t.tenant => {
      logins = [for m in t.members : m.user if try(m.user, null) != null]
    }
    if length([for m in t.members : m.user if try(m.user, null) != null]) > 0
  }
}

resource "vault_jwt_auth_backend_role" "tenant_sso" {
  for_each              = local.tenant_sso
  backend               = "oidc"
  role_name             = "sso-${each.key}"
  role_type             = "oidc"
  user_claim            = "preferred_username"
  oidc_scopes           = ["profile"]
  allowed_redirect_uris = local.oidc_redirect_uris
  token_policies        = [vault_policy.tenant[each.key].name]
  token_ttl             = 3600

  # bound_claims is a map of comma-separated strings (provider docs).
  bound_claims = {
    preferred_username = join(",", each.value.logins)
  }
}
