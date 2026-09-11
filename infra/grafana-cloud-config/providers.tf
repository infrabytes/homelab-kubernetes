provider "grafana" {
  url  = var.grafana_cloud_stack_url
  auth = var.grafana_cloud_stack_sa_token
}

provider "grafana-adaptive-metrics" {
  url     = var.grafana_cloud_prometheus_url
  api_key = "${var.grafana_cloud_prometheus_username}:${var.grafana_cloud_adaptive_metrics_token}"
}
