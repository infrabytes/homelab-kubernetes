resource "terraform_data" "argocd_admin_password_bcrypt" {
  input = bcrypt(var.argocd_admin_password)

  lifecycle {
    ignore_changes = [input]
  }
}

resource "helm_release" "argo_cd" {
  name             = "argo-cd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.8.2"
  namespace        = "argocd"
  create_namespace = true
  wait             = true

  values = [
    yamlencode({
      fullnameOverride = "argocd"
      server = {
        service = { type = "ClusterIP" }
        ingress = { enabled = false }
        metrics = { enabled = true }
        # 14d p95 usage (Grafana Cloud): CPU requests only, memory limit = 1.5x request.
        resources = {
          requests = { cpu = "10m", memory = "128Mi" }
          limits   = { memory = "192Mi" }
        }
      }
      applicationSet = {
        enabled = true
        metrics = { enabled = true }
        resources = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { memory = "96Mi" }
        }
      }
      # Expose the /metrics endpoints as Services so the k8s-monitoring
      # ServiceMonitors in platform/helm-charts/grafana-cloud can scrape them.
      controller = {
        metrics = { enabled = true }
        resources = {
          requests = { cpu = "100m", memory = "608Mi" }
          limits   = { memory = "912Mi" }
        }
      }
      repoServer = {
        metrics = { enabled = true }
        resources = {
          requests = { cpu = "10m", memory = "192Mi" }
          limits   = { memory = "288Mi" }
        }
      }
      dex = {
        resources = {
          requests = { cpu = "10m", memory = "80Mi" }
          limits   = { memory = "120Mi" }
        }
      }
      notifications = {
        resources = {
          requests = { cpu = "10m", memory = "32Mi" }
          limits   = { memory = "48Mi" }
        }
      }
      redis = {
        resources = {
          requests = { cpu = "10m", memory = "32Mi" }
          limits   = { memory = "48Mi" }
        }
      }
      configs = {
        params = {
          "server.insecure" = true
        }
        cm = merge(
          {
            url = "https://argocd.icaninto.space"
            # Local service account for the Terraform argocd provider
            # (infra/argocd-config). apiKey capability only (no login), so
            # the login page stays SSO-only.
            "accounts.tf-bot" = "apiKey"
            # Cap unauthenticated webhook request bodies (DDoS hardening;
            # default 50MB, GitHub push events stay far below 1MB).
            "webhook.maxPayloadSizeMB" = "1"
          },
          # SSO-only login: disable the local admin account once the tf-bot
          # token exists (empty token = still bootstrapping with admin creds).
          var.argocd_tf_token != "" ? {
            "admin.enabled" = "false"
          } : {},
          var.github_oidc_client_id != "" ? {
            "dex.config" = <<-EOT
              connectors:
                - type: github
                  id: github
                  name: GitHub
                  config:
                    clientID: ${var.github_oidc_client_id}
                    clientSecret: $dex.github.clientSecret
                    orgs:
                      - name: ${var.github_oidc_org}
            EOT
          } : {},
        )
        secret = {
          createSecret                   = true
          # Stable hash from state
          argocdServerAdminPassword      = terraform_data.argocd_admin_password_bcrypt.output
          argocdServerAdminPasswordMtime = "2026-08-08T00:00:00Z"
          # Both secrets are optional (empty while bootstrapping): the dex
          # client secret enables SSO, the webhook secret makes the API server
          # verify GitHub webhook signatures (X-Hub-Signature-256).
          extra                          = merge(
            var.github_oidc_client_secret != "" ? {
              "dex.github.clientSecret" = var.github_oidc_client_secret
            } : {},
            var.argocd_webhook_secret != "" ? {
              "webhook.github.secret" = var.argocd_webhook_secret
            } : {}
          )
        }
        # RBAC comes from env.hcl (`addons.argocd_rbac`): policy.default,
        # OIDC scopes, and the policy.csv lines. Only the mandatory tf-bot
        # service-account policy is fixed here: the argocd-config provider
        # needs it to authenticate, so it must survive any env.hcl edit.
        rbac = var.argocd_rbac != null ? {
          "policy.default" = var.argocd_rbac.policy_default
          "policy.csv"     = join("\n", compact(concat(["p, tf-bot, *, *, *, allow"], var.argocd_rbac.policy_csv)))
          scopes           = var.argocd_rbac.scopes
        } : {}
        repositories = var.github_pat != "" ? [
          {
            name     = "homelab-kubernetes"
            url      = var.gitops_repo_url
            username = "git"
            password = var.github_pat
          }
        ] : []
      }
    })
  ]
}

resource "kubernetes_namespace_v1" "cert_manager" {
  metadata { name = "cert-manager" }
}

resource "kubernetes_secret_v1" "cert_manager_cloudflare" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.cert_manager.metadata[0].name
  }
  data = {
    "cloudflare-api-token" = var.cloudflare_api_token
  }
}

resource "kubernetes_namespace_v1" "external_dns" {
  metadata { name = "external-dns" }
}

resource "kubernetes_secret_v1" "external_dns_cloudflare" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.external_dns.metadata[0].name
  }
  data = {
    "cloudflare-api-token" = var.cloudflare_api_token
  }
}

resource "kubernetes_namespace_v1" "openbao" {
  metadata { name = "openbao" }
}

# Static seal key for the built-in auto-unseal (seal "static" stanza, read via
# file:// from the pod). The value in the Secret is the raw 32-byte key; the
# openbao chart (platform/helm-charts/openbao) mounts it at
# /openbao/seal/current.key read-only. Key rotation: write the new key as
# current.key with a previous_key/previous_key_id stanza (see the app README).
resource "kubernetes_secret_v1" "openbao_seal" {
  metadata {
    name      = "openbao-seal"
    namespace = kubernetes_namespace_v1.openbao.metadata[0].name
  }
  binary_data = {
    "current.key" = var.openbao_seal_key
  }
}

# State-held copy of the bootstrap root token (SOPS -> env.hcl -> addons
# inputs). Nothing in the cluster consumes it; the value is kept so recovery/
# rotation workflows never need the token re-typed.
resource "terraform_data" "openbao_root_token" {
  input = var.openbao_root_token
}

resource "kubernetes_namespace_v1" "grafana_cloud" {
  metadata {
    name = "grafana-cloud"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# Credentials consumed by the k8s-monitoring chart (platform/helm-charts/
# grafana-cloud). Key names match the destinations' usernameKey/passwordKey.
resource "kubernetes_secret_v1" "grafana_cloud_credentials" {
  metadata {
    name      = "alloy-secrets"
    namespace = kubernetes_namespace_v1.grafana_cloud.metadata[0].name
  }
  data = {
    "prometheus-username" = var.grafana_cloud_prometheus_username
    "prometheus-token"    = var.grafana_cloud_prometheus_token
    "loki-username"       = var.grafana_cloud_loki_username
    "loki-token"          = var.grafana_cloud_loki_token
  }
}

resource "kubernetes_namespace_v1" "arc_systems" {
  metadata { name = "arc-systems" }
}

resource "kubernetes_namespace_v1" "arc_runners" {
  metadata { name = "arc-runners" }
}

resource "kubernetes_namespace_v1" "argocd_diff_preview" {
  metadata { name = "argocd-diff-preview" }
}
