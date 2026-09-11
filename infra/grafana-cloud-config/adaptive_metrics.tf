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

  # Auto-apply is on: Grafana aggregates labels it sees no queries for, accepted
  # with the 82 pending recommendations that still propose dropping kept labels
  # (keep_labels only constrains newly generated ones).
  #
  # The `no-increase` gate is NOT declared here and cannot be: no provider
  # release has the attribute (0.3.3-0.3.6), and OpenTofu drops unknown keys
  # inside a nested attribute instead of failing — so writing it here is a no-op
  # that would run auto-apply ungated, which is how this bit us once already.
  # The gate is held server-side (the API stores and returns it) and any apply
  # of this resource POSTs a config without it, clearing the gate; re-set it
  # per README.md. Verify with `terragrunt state show`, never by re-reading HCL.
  auto_apply = {
    enabled = true
  }
}
