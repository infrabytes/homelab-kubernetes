# Dashboard JSON exports

Raw JSON for the hand-authored dashboards this unit still owns. Chart-shipped
dashboards are delivered to the stack by grafana-operator
(`platform/grafana-dashboards`), not from here.

Keep the dashboard's existing `uid`: the matching `grafana_dashboard` resource
in `../main.tf` must reference the same uid, otherwise Terraform creates a
duplicate. Keep the `id`/`version` fields as exported (the provider accepts
them) and edit the JSON directly — `terragrunt apply` pushes the change.

## `network-policies.json` (hand-authored)

Policy posture dashboard: which endpoints and namespaces have no policy at
all, and what is being denied. Unlike chart-shipped dashboards this one is not
generated from a chart; edit the JSON directly (Terraform pushes it on apply).

Sources:

- `kube_networkpolicy_created` / `_spec_ingress_rules` / `_spec_egress_rules`
  from kube-state-metrics (allowlisted in
  `platform/helm-charts/grafana-cloud/application.yaml`);
- `cilium_policy` and `cilium_policy_endpoint_enforcement_status` from the
  Cilium agent (`prometheus.enabled` in `infra/cluster/cilium.tf`);
- `hubble_flows_processed_total` and `hubble_drop_total` from the Hubble
  metrics exporter (`hubble.metrics.enabled` in `infra/cluster/cilium.tf`),
  scraped through the PodMonitor in
  `platform/helm-charts/grafana-cloud/cilium-podmonitor.yaml`.

The `${DS_PROM}` placeholder in the templating variable is replaced with the
managed Prometheus datasource uid by the `grafana_dashboard.network_policies`
resource in `../main.tf`.
