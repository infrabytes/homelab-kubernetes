variable "grafana_cloud_stack_url" {
  description = "Grafana Cloud stack base URL (e.g. https://<stack-slug>.grafana.net/). Not a secret; held in the shared SOPS secrets file for consistency."
  type        = string
}

variable "grafana_cloud_stack_sa_token" {
  description = "Grafana Cloud stack service-account token with Admin role. Held in the shared SOPS secrets file."
  type        = string
  sensitive   = true
}

variable "grafana_cloud_prometheus_url" {
  description = "Hosted Prometheus endpoint URL (https://<prom-url>.grafana.net), the base URL of the Adaptive Metrics API. Not a secret; held in the shared SOPS secrets file for consistency."
  type        = string
}

variable "grafana_cloud_prometheus_username" {
  description = "Numeric Grafana Cloud stack instance ID: the tenant half of the Adaptive Metrics api_key (also the remote-write basic-auth username)."
  type        = string
}

variable "grafana_cloud_adaptive_metrics_token" {
  description = "Grafana Cloud access-policy token with the adaptive-metrics-config:read and adaptive-metrics-config:write scopes. Held in the shared SOPS secrets file."
  type        = string
  sensitive   = true
}
