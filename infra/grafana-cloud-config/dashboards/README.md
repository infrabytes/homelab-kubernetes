# Dashboard JSON exports

Raw JSON for the hand-authored dashboards this unit still owns. Chart-shipped
dashboards are delivered to the stack by grafana-operator
(`platform/grafana-dashboards`), not from here.

Keep the dashboard's existing `uid`: the matching `grafana_dashboard` resource
in `../main.tf` must reference the same uid, otherwise Terraform creates a
duplicate. Keep the `id`/`version` fields as exported (the provider accepts
them) and edit the JSON directly — `terragrunt apply` pushes the change.

## Moved out

The hand-authored **Network Policies** dashboard now lives in
`platform/grafana-dashboards/network-policies.yaml` (a ConfigMap + a
`GrafanaDashboard` CR) so the local instance renders it; its `${DS_PROM}`
placeholder is substituted with the `victoriametrics` uid there. The Cloud copy
is deleted with the watchdog cutover.
