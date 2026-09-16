variable "grafana_cloud_stack_url" {
  description = "Grafana Cloud stack base URL (e.g. https://<stack-slug>.grafana.net/). Not a secret; held in the shared SOPS secrets file for consistency."
  type        = string
}

variable "grafana_cloud_stack_sa_token" {
  description = "Grafana Cloud stack service-account token with Admin role. Held in the shared SOPS secrets file."
  type        = string
  sensitive   = true
}
