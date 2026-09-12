# Shared environment configuration: ALL Terragrunt unit inputs are centralized
# here (one local map per unit). Each unit's terragrunt.hcl reads its inputs from
# this single file via read_terragrunt_config(...) and assigns them to `inputs`,
# terragrunt.hcl carries only logic (includes, deps, retries), not values.

locals {
  infra_dir = get_terragrunt_dir()

  gitops_repo_url = "https://github.com/infrabytes/homelab-kubernetes"

  kubeconfig_path = abspath("${local.infra_dir}/cluster/artifacts/kubeconfig")

  secrets = yamldecode(sops_decrypt_file(abspath("${local.infra_dir}/secrets.sops.yaml")))

  cluster = {
    # Write talosconfig/kubeconfig to the real unit dir (Terragrunt runs from
    # .terragrunt-cache).
    artifacts_dir = abspath("${local.infra_dir}/cluster/artifacts")

    proxmox_endpoint  = "https://192.168.0.11:8006/"
    proxmox_api_token = local.secrets.proxmox_api_token
    proxmox_username  = ""
    proxmox_password  = ""
    proxmox_insecure  = true

    cluster_name     = "talos-cluster"
    cluster_endpoint = "https://192.168.0.67:6443"

    talos_version            = "v1.14.0"
    kubernetes_version       = "1.37.0"
    cilium_chart_version     = "1.20.1"
    gateway_api_crds_version = "v1.6.2"

    # Image Factory (standard, non-secureboot metal ISO)
    talos_arch     = "amd64"
    talos_iso_name = "metal-amd64"

    enable_qemu_guest_agent = true

    talos_log_enabled = true
    talos_log_port    = 5140

    # System extensions baked into every node image (qemu-guest-agent is
    # appended automatically). iscsi-tools + util-linux-tools are required by
    # Longhorn on every node.
    talos_system_extensions = ["siderolabs/intel-ucode", "siderolabs/iscsi-tools", "siderolabs/util-linux-tools"]

    proxmox_iso_datastore  = "local"
    proxmox_disk_datastore = "local-lvm"
    proxmox_network_bridge = "vmbr0"
    secure_boot            = false

    nodes = {
      "192.168.0.67" = {
        role           = "controlplane"
        hostname       = "talos-cp-1"
        proxmox_node   = "proxmox01"
        vm_id          = 210
        ipv4_address   = "192.168.0.67"
        ipv4_prefix    = 24
        ipv4_gateway   = "192.168.0.1"
        dns_servers    = ["192.168.0.1"]
        mac_address    = "BC:24:11:00:00:D2"
        cores          = 4
        memory         = 14336
        disk_size      = 80
        swap_disk_size = 4
        # Single controlplane: no drain before OS upgrades (nothing to evict,
        # and a drain can block the upgrade when the cluster is degraded).
        drain_on_upgrade = false
      }
      "192.168.0.68" = {
        role               = "worker"
        hostname           = "talos-worker-1"
        proxmox_node       = "proxmox02"
        vm_id              = 211
        ipv4_address       = "192.168.0.68"
        ipv4_prefix        = 24
        ipv4_gateway       = "192.168.0.1"
        dns_servers        = ["192.168.0.1"]
        mac_address        = "BC:24:11:00:00:D3"
        cores              = 4
        memory             = 14336
        disk_size          = 80
        longhorn_disk_size = 73
        swap_disk_size     = 4
        node_labels        = { "node.longhorn.io/create-default-disk" = "true" }
      }
      "192.168.0.69" = {
        role               = "worker"
        hostname           = "talos-worker-2"
        proxmox_node       = "proxmox03"
        vm_id              = 212
        ipv4_address       = "192.168.0.69"
        ipv4_prefix        = 24
        ipv4_gateway       = "192.168.0.1"
        dns_servers        = ["192.168.0.1"]
        mac_address        = "BC:24:11:00:00:D4"
        cores              = 4
        memory             = 14336
        disk_size          = 80
        longhorn_disk_size = 73
        swap_disk_size     = 4
        node_labels        = { "node.longhorn.io/create-default-disk" = "true" }
      }
      "192.168.0.70" = {
        role               = "worker"
        hostname           = "talos-worker-3"
        proxmox_node       = "proxmox04"
        vm_id              = 213
        ipv4_address       = "192.168.0.70"
        ipv4_prefix        = 24
        ipv4_gateway       = "192.168.0.1"
        dns_servers        = ["192.168.0.1"]
        mac_address        = "BC:24:11:00:00:D5"
        cores              = 4
        memory             = 14336
        disk_size          = 80
        longhorn_disk_size = 73
        swap_disk_size     = 4
        node_labels        = { "node.longhorn.io/create-default-disk" = "true" }
      }
    }
  }

  addons = {
    kubeconfig_path           = local.kubeconfig_path
    gitops_repo_url           = local.gitops_repo_url
    github_pat                = local.secrets.github_pat
    cloudflare_api_token      = local.secrets.cloudflare_api_token
    argocd_admin_password     = local.secrets.argocd_admin_password
    github_oidc_client_id     = local.secrets.github_oidc_client_id
    github_oidc_client_secret = local.secrets.github_oidc_client_secret
    github_oidc_org           = "infrabytes"
    # ArgoCD RBAC (argocd-rbac-cm): policy.default, OIDC scopes, raw policy.csv
    # lines. Bindings use the SSO *username* (GitHub login, preferred_username
    # scope): Dex returns no groups claim for the GitHub connector. The tf-bot
    # service-account line is NOT listed here: the addons unit always prepends
    # `p, tf-bot, *, *, *, allow` (the argocd-config provider needs it; keeping
    # it enforced prevents a mis-edit from locking out Terraform bootstrap).
    argocd_rbac = {
      policy_default = ""
      scopes         = "[groups, preferred_username]"
      policy_csv = [
        "g, bbayrakt, role:admin",
        # dhaustein (pdeu-discord-bot repo owner): read-only everywhere,
        # plus full admin of the pdeu project.
        "g, dhaustein, role:readonly",
        "p, dhaustein, applications, *, pdeu/*, allow",
        "p, dhaustein, applicationsets, *, pdeu/*, allow",
        "p, dhaustein, logs, get, pdeu/*, allow",
        "p, dhaustein, exec, create, pdeu/*, allow",
        "p, dhaustein, projects, update, pdeu, allow",
        "p, dhaustein, repositories, create, pdeu/*, allow",
        "p, dhaustein, repositories, update, pdeu/*, allow",
        "p, dhaustein, repositories, delete, pdeu/*, allow",
      ]
    }
    # ArgoCD SSO-only login: once the tf-bot API token is added below, the
    # local admin account is disabled and the argocd-config provider
    # authenticates with the token instead of the admin password.
    argocd_tf_token = try(local.secrets.argocd_tf_token, "")
    # ArgoCD GitHub webhook shared secret (argocd-secret: webhook.github.secret).
    # The same value goes into the GitHub repo webhook (Settings -> Webhooks);
    # ArgoCD rejects events whose X-Hub-Signature-256 does not match.
    # Generate with: openssl rand -hex 32
    argocd_webhook_secret = try(local.secrets.argocd_webhook_secret, "")

    # Grafana Cloud (free tier) remote-write credentials. Usernames are the
    # stack instance IDs, tokens are access-policy/API tokens scoped to
    # metrics:write and logs:write. Consumed by the k8s-monitoring chart via
    # the alloy-secrets Secret in the grafana-cloud namespace.
    grafana_cloud_prometheus_username = local.secrets.grafana_cloud_prometheus_username
    grafana_cloud_prometheus_token    = local.secrets.grafana_cloud_prometheus_token
    grafana_cloud_loki_username       = local.secrets.grafana_cloud_loki_username
    grafana_cloud_loki_token          = local.secrets.grafana_cloud_loki_token

    # grafana-operator's stack credential (dashboards + folders read/write),
    # materialized as the grafana-operator-token Secret in the grafana-cloud
    # namespace. try() keeps the units valid until the token lands in SOPS.
    grafana_cloud_dashboards_token = try(local.secrets.grafana_cloud_dashboards_token, "")

    # OpenBao static seal key (32 random bytes, base64) and the root token
    # (filled in once, after the one-time `bao operator init` bootstrap).
    openbao_seal_key   = local.secrets.openbao_seal_key
    openbao_root_token = local.secrets.openbao_root_token

    # Standalone Dex (OpenBao SSO, platform/helm-charts/dex): dedicated GitHub
    # OAuth app ("Dex (homelab)") and the Dex static-client secret for the
    # OpenBao oidc auth method. Render the dex-config (config.yaml) and
    # openbao-oidc Secrets. The connector org restriction reuses
    # github_oidc_org.
    dex_github_client_id       = local.secrets.dex_github_client_id
    dex_github_client_secret   = local.secrets.dex_github_client_secret
    openbao_oidc_client_secret = local.secrets.openbao_oidc_client_secret

    # Tailnet Dex: dedicated GitHub OAuth app ("Dex (homelab tailnet)") with
    # callback https://dex.taile70903.ts.net/callback. Reuses the OpenBao
    # static-client secret (openbao_oidc_client_secret) for the tailnet mount.
    dex_tailnet_github_client_id     = local.secrets.dex_tailnet_github_client_id
    dex_tailnet_github_client_secret = local.secrets.dex_tailnet_github_client_secret
  }

  # Grafana Cloud stack API access for the grafana/grafana provider. Manages
  # the talos/cilium folders, the hand-authored network-policies dashboard, the
  # alerting rule groups and (in adaptive_metrics.tf) Adaptive Metrics.
  # Chart-shipped dashboards are NOT managed here: grafana-operator delivers
  # them from the charts (platform/grafana-dashboards). Order-independent unit:
  # it talks to the Grafana Cloud API, not the cluster.
  grafana_cloud = {
    grafana_cloud_stack_url      = local.secrets.grafana_cloud_stack_url
    grafana_cloud_stack_sa_token = local.secrets.grafana_cloud_stack_sa_token

    # Adaptive Metrics is served from the hosted Prometheus endpoint, not the
    # stack URL, and takes a tenant ID + access-policy token rather than the
    # stack service-account token. try() keeps the units valid until that
    # access policy token lands in SOPS.
    grafana_cloud_prometheus_url         = local.secrets.grafana_cloud_prometheus_url
    grafana_cloud_prometheus_username    = local.secrets.grafana_cloud_prometheus_username
    grafana_cloud_adaptive_metrics_token = try(local.secrets.grafana_cloud_adaptive_metrics_token, "")
  }

  argocd_config = {
    kubeconfig_path       = local.kubeconfig_path
    gitops_repo_url       = local.gitops_repo_url
    argocd_admin_password = local.secrets.argocd_admin_password
    # Used by the argocd provider when the local admin login is disabled
    # (SSO-only mode). Falls back to admin password while empty (bootstrap).
    argocd_tf_token = try(local.secrets.argocd_tf_token, "")
  }

  viewer_kubeconfig = {
    kubeconfig_path = local.kubeconfig_path
    # Write the viewer kubeconfig next to the admin kubeconfig (gitignored).
    artifacts_dir = abspath("${local.infra_dir}/cluster/artifacts")
    cluster_name  = "talos-cluster"
    user_name     = "viewer@talos-cluster"
  }
}
