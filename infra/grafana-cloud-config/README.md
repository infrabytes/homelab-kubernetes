# grafana-cloud-config (Grafana Cloud watchdog)

Manages the **out-of-cluster watchdog** on Grafana Cloud Free with the
[grafana/grafana](https://registry.terraform.io/providers/grafana/grafana/latest)
provider. After the cutover the cluster's metrics and logs live in the local
stack (`platform/observability`), so everything that used to be managed here —
the cluster rule groups, the Cilium folder, the hand-authored Network Policies
dashboard, Adaptive Metrics — moved there or was deleted. What is left is only
what must survive the cluster dying:

- the **Talos folder** and the **PVE-maintenance dashboard**;
- the **`proxmox-maintenance` rules** (fed by `ansible/proxmox-node-updates.yml`
  pushing to Cloud Loki) and the **`watchdog` rule** ("Cluster heartbeat
  missing", fed by `platform/observability/heartbeat-cronjob.yaml`).

This is a dead-man switch, not a monitoring stack: keep it small, and keep every
rule's data source something the cluster cannot deliver itself. The heartbeat
rule is the one that catches "the cluster is gone"; the maintenance rules catch
"the maintenance automation is gone".

The **Discord contact point (`GrafanaBot`) and the notification policy rooted at
it are hand-configured** in the stack — the watchdog rules notify through them
unchanged. Adopt them with the import workflow below if they should become
managed (a `grafana_contact_point` + `grafana_notification_policy` pair; the
webhook URL lives in the stack and is not readable back, so it would have to be
supplied from SOPS).

Order-independent unit: the provider talks to the Grafana Cloud API, not the
cluster, so `apply --all` runs it in parallel with the other units.

## Requirements

- Entries in `infra/secrets.sops.yaml` (edit from the host with `sops`):
  - `grafana_cloud_stack_url`: stack base URL, e.g. `https://<stack-slug>.grafana.net/`
  - `grafana_cloud_stack_sa_token`: stack **service-account token with the
    Admin role** (Grafana Cloud → stack → Administration → Service accounts).
    Admin covers dashboards/folders/alerting endpoints; a tighter token with
    `grafana-dashboards-read-write`, `alerting:read/write` and
    `datasources:read` scopes works too.
  - `grafana_cloud_loki_username` / `grafana_cloud_loki_token` are **not** used
    by this unit: they belong to the heartbeat CronJob and the Ansible playbook
    (the addons unit materializes them into the `alloy-secrets` Secret).
- `infra/env.hcl` maps the two stack values into `locals.grafana_cloud`, wired by
  `terragrunt.hcl` (`inputs = local.env.locals.grafana_cloud`).

## Adopting existing (hand-configured) resources

1. Export any existing dashboard from the UI (Share → Export → Download JSON)
   into `dashboards/<name>.json`, keeping the original `uid`. Note the folder
   UIDs, alert-rule group names and contact point names in use.
2. Write the matching resources in `main.tf` so the config matches the live
   state (same uids, same rule-group names, same contact point names).
3. Import each resource into state (config must exist first, then import):

   ```sh
   cd infra/grafana-cloud-config
   terragrunt import 'grafana_folder.<name>' "<uid>"
   terragrunt import 'grafana_dashboard.<name>' "<uid>"
   terragrunt import 'grafana_contact_point.<name>' "<name>"
   terragrunt import 'grafana_rule_group.<name>' "<folderUID>:<groupName>"
   terragrunt import 'grafana_notification_policy.root' "policy"
   terragrunt import 'grafana_organization_preferences.main' "<orgID>"
   ```

4. Gate: `terragrunt plan` must show **zero changes** before the first apply.
   Treat any diff as a decision: keep the live state (adopt the config to
   match it) or accept the config (apply overwrites the UI state).

## Adding a rule

Add a `grafana_rule_group` (see `main.tf`). Loki rules read the auto-provisioned
managed Loki datasource (`grafanacloud-<stack-slug>-logs`, resolved read-only via
`data.grafana_data_source.loki.uid`) with `query_type = "range"` and a 900s
window, feed a `reduce` expression (`reducer = "last"`) and a threshold;
`no_data_state = "Alerting"` is what makes a dead-man rule fire when the data
disappears (any other state turns the silence into no alert at all). Prometheus
rules, if one is ever needed here, resolve
`grafanacloud-<stack-slug>-prom` the same way and must use the `bool` modifier
for comparisons (`up == bool 0`) — a plain comparison keeps the sample's value
instead of yielding 1, so the threshold never fires.

## Caveats

- Resources created here are flagged **provisioned** in the Grafana UI: stop
  hand-editing them, or `terragrunt plan` reports drift.
- `grafana_notification_policy` **replaces the entire policy tree** on apply —
  it must always contain the full routing (root contact point + all nested
  policies). It is deliberately not managed here yet (see above).
- Free tier: one stack only; SLOs and stack-level settings are out of scope
  (they need a cloud access-policy token and the `grafana.cloud` provider block).
- The Cloud dashboards the chart-shipped dashboards used to be delivered into
  (Cilium/External Secrets/OpenBao) are gone; grafana-operator now renders them
  into the local instance instead (`platform/grafana-dashboards/`).
