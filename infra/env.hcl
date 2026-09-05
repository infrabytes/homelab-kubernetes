# Shared environment configuration: ALL Terragrunt unit inputs are centralized
# here (one local map per unit). Each unit's terragrunt.hcl reads its inputs from
# this single file via read_terragrunt_config(...) and assigns them to `inputs`,
# terragrunt.hcl carries only logic (includes, deps, retries), not values.

locals {
  infra_dir = get_terragrunt_dir()

  gitops_repo_url = "https://github.com/infrabytes/homelab-kubernetes"

  kubeconfig_path = abspath("${local.infra_dir}/cluster/artifacts/kubeconfig")

  secrets = yamldecode(sops_decrypt_file(abspath("${local.infra_dir}/secrets.sops.yaml")))

  # ---------------------------------------------------------------------------
  # cluster unit inputs
  # ---------------------------------------------------------------------------
  cluster = {
    # Write talosconfig/kubeconfig to the real unit dir (Terragrunt runs from
    # .terragrunt-cache).
    artifacts_dir = abspath("${local.infra_dir}/cluster/artifacts")

    # Proxmox connection
    proxmox_endpoint  = "https://192.168.0.11:8006/"
    proxmox_api_token = local.secrets.proxmox_api_token
    proxmox_username  = ""
    proxmox_password  = ""
    proxmox_insecure  = true

    # Cluster
    cluster_name     = "talos-cluster"
    cluster_endpoint = "https://192.168.0.67:6443"

    # Versions
    talos_version            = "v1.14.0"
    kubernetes_version       = "1.37.0"
    cilium_chart_version     = "1.20.1"
    gateway_api_crds_version = "v1.6.2"

    # Image Factory (standard, non-secureboot metal ISO)
    talos_arch     = "amd64"
    talos_iso_name = "metal-amd64"

    enable_qemu_guest_agent = true

    # Talos machine log forwarding
    talos_log_enabled = true
    talos_log_port    = 5140

    # System extensions baked into every node image (qemu-guest-agent is
    # appended automatically). iscsi-tools + util-linux-tools are required by
    # Longhorn on every node.
    talos_system_extensions = ["siderolabs/intel-ucode", "siderolabs/iscsi-tools", "siderolabs/util-linux-tools"]

    # Proxmox storage/network defaults
    proxmox_iso_datastore  = "local"
    proxmox_disk_datastore = "local-lvm"
    proxmox_network_bridge = "vmbr0"
    secure_boot            = false

    # Nodes
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
        cores          = 2
        memory         = 4096
        disk_size      = 40
        swap_disk_size = 4
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

  # ---------------------------------------------------------------------------
  # addons unit inputs
  # ---------------------------------------------------------------------------
  addons = {
    kubeconfig_path           = local.kubeconfig_path
    gitops_repo_url           = local.gitops_repo_url
    github_pat                = local.secrets.github_pat
    cloudflare_api_token      = local.secrets.cloudflare_api_token
    argocd_admin_password     = local.secrets.argocd_admin_password
    github_oidc_client_id     = local.secrets.github_oidc_client_id
    github_oidc_client_secret = local.secrets.github_oidc_client_secret
    github_oidc_org           = "infrabytes"
    # ArgoCD RBAC (argocd-rbac-cm), configured here rather than in the addons
    # unit: policy.default, the OIDC scopes to read for RBAC, and the raw
    # policy.csv lines (any ArgoCD RBAC syntax is expressible).
    #
    # Bindings must use the SSO *username* (GitHub login, from the
    # preferred_username scope): Dex returns no groups claim for the GitHub
    # connector, so an org-name binding would never match with
    # policy.default = "". Note bbayrakt's account kept its name when the repo
    # moved to the infrabytes org.
    #
    # The tf-bot service-account line is NOT listed here — the addons unit
    # always prepends `p, tf-bot, *, *, *, allow` (the argocd-config provider
    # needs it to authenticate; keeping it enforced prevents a mis-edit from
    # locking out Terraform bootstrap).
    argocd_rbac = {
      policy_default = ""
      scopes         = "[groups, preferred_username]"
      policy_csv = [
        # bbayrakt: cluster admin.
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
    argocd_tf_token     = try(local.secrets.argocd_tf_token, "")
    github_runner_token = local.secrets.github_runner_token
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
  }

  # ---------------------------------------------------------------------------
  # grafana-cloud-config unit inputs
  # ---------------------------------------------------------------------------
  # Grafana Cloud stack API access for the grafana/grafana provider. Manages
  # dashboards, folders, alerting (rule groups, contact points, notification
  # policies, message templates) and org preferences on the existing stack.
  # Order-independent unit: it talks to the Grafana Cloud API, not the cluster.
  grafana_cloud = {
    grafana_cloud_stack_url      = local.secrets.grafana_cloud_stack_url
    grafana_cloud_stack_sa_token = local.secrets.grafana_cloud_stack_sa_token
  }

  # ---------------------------------------------------------------------------
  # argocd-config unit inputs
  # ---------------------------------------------------------------------------
  argocd_config = {
    kubeconfig_path       = local.kubeconfig_path
    gitops_repo_url       = local.gitops_repo_url
    argocd_admin_password = local.secrets.argocd_admin_password
    # Used by the argocd provider when the local admin login is disabled
    # (SSO-only mode). Falls back to admin password while empty (bootstrap).
    argocd_tf_token = try(local.secrets.argocd_tf_token, "")
  }

  # ---------------------------------------------------------------------------
  # viewer-kubeconfig unit inputs
  # ---------------------------------------------------------------------------
  viewer_kubeconfig = {
    kubeconfig_path = local.kubeconfig_path
    # Write the viewer kubeconfig next to the admin kubeconfig (gitignored).
    artifacts_dir = abspath("${local.infra_dir}/cluster/artifacts")
    cluster_name  = "talos-cluster"
    user_name     = "viewer@talos-cluster"
  }
}
