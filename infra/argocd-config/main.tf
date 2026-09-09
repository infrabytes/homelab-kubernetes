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
