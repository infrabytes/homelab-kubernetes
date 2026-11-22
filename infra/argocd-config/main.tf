resource "argocd_application_set" "bootstrap" {
  metadata {
    name      = "bootstrap"
    namespace = "argocd"
  }

  spec {
    generator {
      git {
        repo_url = var.gitops_repo_url
        revision = "main"
        directory {
          path = "argocd/appsets/*"
        }
      }
    }

    template {
      metadata {
        name = "appset-{{path.basename}}"
      }
      spec {
        project = "default"
        source {
          repo_url        = var.gitops_repo_url
          target_revision = "main"
          path            = "{{path}}"
          directory {
            recurse = true
          }
        }
        destination {
          server = "https://kubernetes.default.svc"
        }
        sync_policy {
          automated {
            prune     = true
            self_heal = true
          }
          retry {
            limit = "5"
            backoff {
              duration     = "30s"
              max_duration = "5m"
              factor       = "2"
            }
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# gurkerl: the Factory-managed application repo (private). The repo URL and
# its credential come from SOPS — the public homelab repo never names them.
# Same guardrails the pdeu appset carries: the project's own namespaces only
# (gurkerl-*), namespaced resources only, Role/RoleBinding blacklisted so the
# agent cannot escalate; new app namespaces are self-serve (CreateNamespace).
# ---------------------------------------------------------------------------
resource "argocd_project" "gurkerl" {
  metadata {
    name      = "gurkerl"
    namespace = "argocd"
  }

  spec {
    description  = "Factory-managed gurkerl app deployments (private repo; URL in SOPS)"
    source_repos = [var.gurkerl_repo_url]

    destination {
      server    = "https://kubernetes.default.svc"
      namespace = "gurkerl-*"
    }

    namespace_resource_whitelist {
      group = "*"
      kind  = "*"
    }

    namespace_resource_blacklist {
      group = "rbac.authorization.k8s.io"
      kind  = "Role"
    }

    namespace_resource_blacklist {
      group = "rbac.authorization.k8s.io"
      kind  = "RoleBinding"
    }
  }
}

resource "argocd_repository" "gurkerl" {
  count = var.gurkerl_pat != "" ? 1 : 0

  repo     = var.gurkerl_repo_url
  username = "git"
  password = var.gurkerl_pat
  project  = argocd_project.gurkerl.metadata[0].name
}

resource "argocd_application_set" "gurkerl" {
  metadata {
    name      = "gurkerl"
    namespace = "argocd"
  }

  spec {
    generator {
      git {
        repo_url = var.gurkerl_repo_url
        revision = "main"
        directory {
          path = "deploy/*"
        }
      }
    }

    template {
      metadata {
        name = "gurkerl-{{path.basename}}"
      }
      spec {
        project = "gurkerl"
        source {
          repo_url        = var.gurkerl_repo_url
          target_revision = "main"
          path            = "{{path}}"
          directory {
            recurse = true
          }
        }
        destination {
          server    = "https://kubernetes.default.svc"
          namespace = "gurkerl-{{path.basename}}"
        }
        sync_policy {
          automated {
            prune     = true
            self_heal = true
          }
          sync_options = ["ServerSideApply=true", "CreateNamespace=true"]
          retry {
            limit = "5"
            backoff {
              duration     = "30s"
              max_duration = "5m"
              factor       = "2"
            }
          }
        }
      }
    }
  }
}
