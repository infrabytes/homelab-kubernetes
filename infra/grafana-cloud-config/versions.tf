terraform {
  required_version = ">= 1.7"

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.28"
    }
    # Retired with the Cloud data path; kept one cycle so the state entry of
    # grafana-adaptive-metrics_recommendations_config.singleton can be destroyed
    # (its delete is a no-op on the stack). Drop the provider, its block and the
    # grafana_cloud_prometheus_*/adaptive_metrics_token inputs in a follow-up.
    grafana-adaptive-metrics = {
      source  = "grafana/grafana-adaptive-metrics"
      version = "~> 0.3"
    }
  }
}
