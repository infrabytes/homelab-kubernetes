# Grafana Cloud Adaptive Metrics. Server-side only: no Kubernetes manifests,
# no data-path changes — this configures which label sets the recommendations
# service must never propose aggregating.

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

  # Auto-apply stays off until a provider release supports the `no-increase`
  # gate. Declaring `auto_apply.gate` today is silently discarded — no released
  # provider has the attribute (0.3.3-0.3.6), and OpenTofu drops unknown keys
  # inside a nested attribute instead of failing validation — which would run
  # auto-apply with every recommendation applied. See README.md.
  auto_apply = {
    enabled = false
  }
}
