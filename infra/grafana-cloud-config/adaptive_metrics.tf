# Grafana Cloud Adaptive Metrics. Server-side only: no Kubernetes manifests,
# no data-path changes — this configures which label sets the recommendations
# service must never propose aggregating, and whether it may apply the rest on
# its own.

# Singleton: the config always exists for the tenant, so create/delete only add
# or remove it from state (the provider warns about this on apply). `keep_labels`
# is an allowlist of labels to keep; everything else becomes aggregatable. It
# only affects newly generated recommendations — rules that already drop one of
# these labels are left alone.
resource "grafana-adaptive-metrics_recommendations_config" "singleton" {
  keep_labels = [
    "pod",
    "namespace",
    "container",
    "instance",
    "job",
    "node",
    "cluster",
    "phase",
    "deployment",
    "daemonset",
    "statefulset",
  ]

  # Hands-off auto-apply, gated to never increase cardinality: a recommendation
  # whose net series change would be positive is skipped rather than applied, so
  # dashboards that do not exist yet cannot lose a label to a bad aggregation.
  auto_apply = {
    enabled = true
    gate = {
      policy = "no-increase"
    }
  }
}
