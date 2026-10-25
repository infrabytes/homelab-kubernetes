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
  version          = "10.10.5"
  namespace        = "argocd"
  create_namespace = true
  wait             = true

  values = [
    yamlencode({
      fullnameOverride = "argocd"
      # The issuer name is a LAN-only override that cluster DNS does not know, so
      # pin it to the VIP for the server's discovery, JWKS and token calls.
      global = {
        hostAliases = [
          {
            ip        = "192.168.0.200"
            hostnames = ["authentik.icaninto.space"]
          }
        ]
      }
      server = {
        service = { type = "ClusterIP" }
        ingress = { enabled = false }
        metrics = { enabled = true }
        # Re-derived 2026-09-16..10-22 (36d retained, local VictoriaMetrics): p95 124.9Mi
        # → 128Mi request; limit = max(1.5x request 192Mi, 1.25x peak 203.3Mi) = 256Mi.
        # The 192Mi/288Mi it replaces came from a 2-day window.
        resources = {
          requests = { cpu = "10m", memory = "128Mi" }
          limits   = { memory = "256Mi" }
        }
      }
      applicationSet = {
        enabled = true
        metrics = { enabled = true }
        # Re-derived 2026-09-16..10-22 (36d retained): p95 132.8Mi → 192Mi request (the old
        # 128Mi sat below its own p95); the 255.7Mi peak sat at 0.999 of the old 256Mi limit,
        # so limit = 1.25x peak = 320Mi. Retires the 2026-09-24 escalation.
        resources = {
          requests = { cpu = "10m", memory = "192Mi" }
          limits   = { memory = "320Mi" }
        }
      }
      # Expose the /metrics endpoints as Services so the k8s-monitoring
      # ServiceMonitors in platform/k8s-monitoring can scrape them.
      controller = {
        metrics = { enabled = true }
        # cpu p95 136m, memory p95 704.4Mi over 2026-09-16..10-22 (36d retained); 44 apps
        # lifted the steady memory p95 to ~840Mi (30d retained), hence the 1Gi request.
        # The limit cannot be derived from history — the series is censored by it:
        # fleet-wide sync bursts OOMKilled the controller at 1152Mi (2026-10-24, 18 apps in
        # 30s) and at 2Gi (2026-10-25, all 44 apps re-synced on one revision; the 30s
        # cadvisor scrape peaked at 2047Mi, the real spike falls between scrapes). 3Gi is
        # a dated escalation; re-measure 2026-11-08.
        resources = {
          requests = { cpu = "140m", memory = "1Gi" }
          limits   = { memory = "3Gi" }
        }
      }
      repoServer = {
        metrics = { enabled = true }
        # Re-derived 2026-09-16..10-22 (36d retained): steady p95 136.7Mi → 192Mi request and
        # cpu p95 88m → 90m; the 518.6Mi peak is the full-fleet render burst (minutes, not
        # steady state), so the limit stays on it: 1.25x = 648Mi → 704Mi.
        resources = {
          requests = { cpu = "90m", memory = "192Mi" }
          limits   = { memory = "704Mi" }
        }
      }
      # Embedded Dex stays off: ArgoCD logs in directly against Authentik. With
      # dex.config set its verifier rewrites the JWKS fetch to Dex (upstream bug),
      # so Authentik ID tokens fail the signature check on Dex's keys.
      dex = { enabled = false }
      notifications = {
        # Re-derived 2026-09-16..10-22 (36d retained, local VictoriaMetrics): the working
        # set is dominated by page cache (RSS flat at ~29Mi), so a cache-warm pod holds
        # p95 58.1Mi and peaked at 63.7Mi — 0.995 of the old 64Mi limit, which the
        # RSS-derived 32Mi/64Mi under-sized. Limit = max(1.5x request, 1.25x peak 79.6Mi).
        resources = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { memory = "96Mi" }
        }
      }
      redis = {
        resources = {
          requests = { cpu = "10m", memory = "64Mi" }
          limits   = { memory = "96Mi" }
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
          # SSO login (direct Authentik OIDC, no embedded Dex); the issuer keeps
          # the trailing slash Authentik emits, and clientSecret comes from
          # argocd-secret via the chart's secret.extra.
          {
            "oidc.config" = <<-EOT
              name: Authentik
              issuer: https://authentik.icaninto.space/application/o/argocd/
              clientID: argocd
              clientSecret: $oidc.clientSecret
              requestedScopes: ["openid", "profile", "email", "groups"]
              enablePKCEAuthentication: true
            EOT
          },
        )
        secret = {
          createSecret = true
          # Stable hash from state
          argocdServerAdminPassword      = terraform_data.argocd_admin_password_bcrypt.output
          argocdServerAdminPasswordMtime = "2026-08-08T00:00:00Z"
          # The webhook secret is optional (empty while bootstrapping): it makes
          # the API server verify GitHub webhook signatures (X-Hub-Signature-256).
          # The Authentik OIDC secret is unconditional: oidc.config names it.
          extra = merge(
            var.argocd_webhook_secret != "" ? {
              "webhook.github.secret" = var.argocd_webhook_secret
            } : {},
            {
              "oidc.clientSecret" = var.authentik_argocd_client_secret
            }
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
# openbao chart (platform/openbao) mounts it at
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

resource "kubernetes_namespace_v1" "dex" {
  metadata { name = "dex" }
}

# Standalone Dex config (config.yaml), rendered from SOPS vars and consumed by
# the dex chart (platform/dex) via configSecret.name=dex-config.
# GitHub connector restricted to github_oidc_org; static clients: OpenBao (UI +
# CLI callback), Grafana and Headlamp (LAN + tailnet hostnames).
resource "kubernetes_secret_v1" "dex_config" {
  metadata {
    name      = "dex-config"
    namespace = kubernetes_namespace_v1.dex.metadata[0].name
  }
  data = {
    "config.yaml" = <<-EOT
      issuer: https://dex.icaninto.space
      storage:
        type: memory
      web:
        # Keep quoted: dex >=2.46 fails on unquoted YAML numbers at config load.
        http: "5556"
      connectors:
        - type: github
          id: github
          name: GitHub
          config:
            clientID: ${var.dex_github_client_id}
            clientSecret: ${var.dex_github_client_secret}
            # Must match the OAuth app's registered callback URL; Dex rejects
            # callbacks that don't match.
            redirectURI: https://dex.icaninto.space/callback
            orgs:
              - name: ${var.github_oidc_org}
      staticClients:
        - id: openbao
          name: OpenBao
          secret: ${var.openbao_oidc_client_secret}
          redirectURIs:
            - https://bao.icaninto.space/ui/vault/auth/oidc/oidc/callback
            - http://localhost:8250/oidc/callback
        - id: grafana
          name: Grafana
          secret: ${var.grafana_oauth_client_secret}
          redirectURIs:
            - https://grafana.icaninto.space/login/generic_oauth
        - id: headlamp
          name: Headlamp
          secret: ${var.headlamp_oidc_client_secret}
          redirectURIs:
            # Headlamp derives the callback from the request host, so both
            # public hostnames must be registered.
            - https://headlamp.icaninto.space/oidc-callback
            - https://headlamp.taile70903.ts.net/oidc-callback
      oauth2:
        skipApprovalScreen: true
      enablePasswordDB: false
    EOT
  }
}

# OIDC client credentials for the OpenBao oidc auth method (Authentik provider
# "openbao"). Injected into the OpenBao pods by the chart's
# server.extraSecretEnvironmentVars (OIDC_CLIENT_ID/OIDC_CLIENT_SECRET).
resource "kubernetes_secret_v1" "openbao_oidc" {
  metadata {
    name      = "openbao-oidc"
    namespace = kubernetes_namespace_v1.openbao.metadata[0].name
  }
  data = {
    "client-id"     = "openbao"
    "client-secret" = var.openbao_oidc_client_secret
  }
}

resource "kubernetes_namespace_v1" "headlamp" {
  metadata { name = "headlamp" }
}

# Headlamp's envFrom source (wired via config.oidc.externalSecret in
# platform/headlamp/application.yaml): the keys become the -oidc-* args.
resource "kubernetes_secret_v1" "headlamp_oidc" {
  metadata {
    name      = "headlamp-oidc"
    namespace = kubernetes_namespace_v1.headlamp.metadata[0].name
  }
  data = {
    OIDC_CLIENT_ID     = "headlamp"
    OIDC_CLIENT_SECRET = var.headlamp_oidc_client_secret
    OIDC_ISSUER_URL    = "https://dex.icaninto.space"
    OIDC_SCOPES        = "openid,profile,email"
  }
}

resource "kubernetes_namespace_v1" "k8s_monitoring" {
  metadata {
    name = "k8s-monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# Loki credentials for the cluster-heartbeat CronJob, the only remaining
# consumer in this namespace (the prometheus-* keys went with the Alloy repoint).
resource "kubernetes_secret_v1" "grafana_cloud_credentials" {
  metadata {
    name      = "alloy-secrets"
    namespace = kubernetes_namespace_v1.k8s_monitoring.metadata[0].name
  }
  data = {
    "loki-username" = var.grafana_cloud_loki_username
    "loki-token"    = var.grafana_cloud_loki_token
  }
}

resource "kubernetes_namespace_v1" "arc_systems" {
  metadata { name = "arc-systems" }
}

resource "kubernetes_namespace_v1" "arc_runners" {
  metadata { name = "arc-runners" }
}

# Terraform owns the alert-triage namespace: the webhook token Secret must exist before
# the ArgoCD sync of platform/alert-triage can start the EventSource (same reasoning as
# the observability namespace below).
resource "kubernetes_namespace_v1" "alert_triage" {
  metadata { name = "alert-triage" }
}

# Bearer token the Grafana contact point sends to the Argo Events webhook EventSource.
# Two copies because a Grafana contact point can only read Secrets in its own namespace;
# the observability copy lives in grafana-notification-secrets below.
resource "kubernetes_secret_v1" "alert_triage_webhook" {
  metadata {
    name      = "alert-triage-webhook"
    namespace = kubernetes_namespace_v1.alert_triage.metadata[0].name
  }
  data = {
    "token" = var.alert_triage_webhook_token
  }
}

# Terraform owns the observability namespace (like openbao/dex): on a cold bootstrap this unit
# runs before ArgoCD exists, so an ArgoCD-owned namespace would fail the apply.
# Keep the import block: without it a re-apply fails on the already-existing namespace.
import {
  to = kubernetes_namespace_v1.observability
  id = "observability"
}

resource "kubernetes_namespace_v1" "observability" {
  metadata { name = "observability" }
}

# Local Grafana (platform/observability/grafana.yaml). The admin/OAuth data keys
# match the env vars the Grafana CR injects; grafana-operator reads them back
# from the live Deployment for its own API client. The notification Secrets are
# read by the contact point's valuesFrom instead.
import {
  to = kubernetes_secret_v1.grafana_admin_credentials
  id = "observability/grafana-admin-credentials"
}

import {
  to = kubernetes_secret_v1.grafana_pg_backup_s3
  id = "observability/grafana-pg-backup-s3"
}

# Barman object store credentials for the Grafana Postgres cluster
# (platform/observability/grafana-postgres.yaml).
resource "kubernetes_secret_v1" "grafana_pg_backup_s3" {
  metadata {
    name      = "grafana-pg-backup-s3"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  type = "Opaque"
  data = {
    ACCESS_KEY_ID     = var.seaweedfs_access_key
    SECRET_ACCESS_KEY = var.seaweedfs_secret_key
  }
}

import {
  to = kubernetes_secret_v1.grafana_oauth_credentials
  id = "observability/grafana-oauth-credentials"
}

import {
  to = kubernetes_secret_v1.grafana_notification_secrets
  id = "observability/grafana-notification-secrets"
}

resource "kubernetes_secret_v1" "grafana_admin_credentials" {
  metadata {
    name      = "grafana-admin-credentials"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = {
    "GF_SECURITY_ADMIN_USER"     = "admin"
    "GF_SECURITY_ADMIN_PASSWORD" = var.grafana_admin_password
  }
}

resource "kubernetes_secret_v1" "grafana_oauth_credentials" {
  metadata {
    name      = "grafana-oauth-credentials"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = {
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = var.grafana_oauth_client_secret
  }
}

resource "kubernetes_secret_v1" "grafana_notification_secrets" {
  metadata {
    name      = "grafana-notification-secrets"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = {
    discord_webhook_url = var.grafana_discord_webhook_url
    alert_triage_token  = var.alert_triage_webhook_token
  }
}

# Read-only Grafana MCP server (platform/grafana-mcp): the Viewer
# service-account token it uses for Grafana, plus the caller bearer token that
# guards its LAN route. Terraform-owned (not ESO) so the Secret exists before
# the ArgoCD-managed app first syncs.
resource "kubernetes_secret_v1" "grafana_mcp_credentials" {
  metadata {
    name      = "grafana-mcp-credentials"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = {
    "grafana-token" = var.grafana_mcp_service_account_token
    "server-token"  = var.grafana_mcp_server_token
  }
}

# Read-only GitHub PAT for the Grafana GitHub data source that the runner
# dashboard links runs through (platform/observability/grafana-github-datasource.yaml).
resource "kubernetes_secret_v1" "grafana_github_token" {
  metadata {
    name      = "grafana-github-token"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = {
    token = var.github_grafana_token
  }
}
