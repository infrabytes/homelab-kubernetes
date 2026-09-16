provider "grafana" {
  url  = var.grafana_cloud_stack_url
  auth = var.grafana_cloud_stack_sa_token
}
