terraform {
  required_version = ">= 1.7"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.28"
    }
    grafana-adaptive-metrics = {
      source  = "grafana/grafana-adaptive-metrics"
      version = "~> 0.3"
    }
  }
}
