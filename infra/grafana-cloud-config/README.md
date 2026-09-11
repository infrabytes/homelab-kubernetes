# grafana-cloud-config (Grafana Cloud as code)

Manages the **Grafana Cloud side** of the stack as code with the
[grafana/grafana](https://registry.terraform.io/providers/grafana/grafana/latest)
provider: dashboards, folders, alerting (rule groups, contact points,
notification policies, message templates, mute timings) and org preferences.
[Adaptive Metrics](#adaptive-metrics) is managed with the
[grafana/grafana-adaptive-metrics](https://registry.terraform.io/providers/grafana/grafana-adaptive-metrics/latest)
provider.

This is the companion to `platform/helm-charts/grafana-cloud/`, which handles
the **data flow** into Grafana Cloud (Alloy collectors pushing metrics/logs).
Everything managed here lives on the existing free-tier stack; the stack itself
is not managed (single stack, no `grafana_cloud_stack` resource).

Order-independent unit: the provider talks to the Grafana Cloud API, not the
cluster, so `apply --all` runs it in parallel with the other units (canonical
ordering: after `addons`, before `argocd-config`).

## Requirements

- Entries in `infra/secrets.sops.yaml` (edit from the host with `sops`):
  - `grafana_cloud_stack_url`: stack base URL, e.g. `https://<stack-slug>.grafana.net/`
  - `grafana_cloud_stack_sa_token`: stack **service-account token with the
    Admin role** (Grafana Cloud → stack → Administration → Service accounts).
    Admin covers dashboards/folders/alerting/org-preferences endpoints; a
    tighter token with `grafana-dashboards-read-write`, `alerting:read/write`
    and `datasources:read` scopes works too.
  - `grafana_cloud_prometheus_url`: hosted Prometheus endpoint URL
    (`https://<prom-url>.grafana.net`, from the Details page of the hosted
    Prometheus endpoint). Base URL of the Adaptive Metrics API.
  - `grafana_cloud_prometheus_username`: numeric stack instance ID (the
    **Username / Instance ID** on the same Details page).
  - `grafana_cloud_adaptive_metrics_token`: access-policy token with
    `adaptive-metrics-config:read` and `adaptive-metrics-config:write`. The
    portal exposes those two for the config endpoint even though the
    [HTTP API docs](https://grafana.com/docs/grafana-cloud/adaptive-telemetry/adaptive-metrics/manage-as-code/adaptive-metrics-api/)
    name a non-grantable `adaptive-metrics-recommendations:write`.
    `adaptive-metrics-recommendations:read` only matters for listing
    recommendations; the provider does not need it.
- `infra/env.hcl` maps them into `locals.grafana_cloud`, wired by
  `terragrunt.hcl` (`inputs = local.env.locals.grafana_cloud`).

## Adopting existing (hand-configured) resources

1. Export every existing dashboard from the UI (Share → Export → Download
   JSON) into `dashboards/<name>.json`, keeping the original `uid`s. Note the
   folder UIDs, alert-rule group names and contact point names in use.
2. Write the matching resources in `main.tf` so the config matches the
   live state (same uids, same rule-group names, same contact point names).
3. Import each resource into state (config must exist first, then import):

   ```sh
   cd infra/grafana-cloud-config
   terragrunt import 'grafana_folder.<name>' "<uid>"
   terragrunt import 'grafana_dashboard.<name>' "<uid>"
   terragrunt import 'grafana_contact_point.<name>' "<name>"
   terragrunt import 'grafana_rule_group.<name>' "<folderUID>:<groupName>"
   terragrunt import 'grafana_message_template.<name>' "<name>"
   terragrunt import 'grafana_notification_policy.root' "policy"
   terragrunt import 'grafana_organization_preferences.main' "<orgID>"
   ```

4. Gate: `terragrunt plan` must show **zero changes** before the first apply.
   Treat any diff as a decision: keep the live state (adopt the config to
   match it) or accept the config (apply overwrites the UI state).

## Adding something new

- **Dashboard**: drop the exported JSON in `dashboards/`, add a
  `grafana_dashboard` resource with `config_json = file("...")`, `terragrunt apply`.
- **Alert rule**: add a `grafana_rule_group` (see the live groups in `main.tf`).
  Queries hit the auto-provisioned managed Prometheus datasource
  (`grafanacloud-<stack-slug>-prom`, resolved read-only via
  `data.grafana_data_source.prom.uid` in `main.tf`). Every rule is an
  **instant** query (`instant: true`, `range: false`, `query_type =
  "prometheus"`) feeding a threshold expression (`expression = "query"`,
  `gt 0`). PromQL comparisons need the `bool` modifier (`up == bool 0`,
  `count(...) > bool 9000`): plain comparisons keep the matching sample's
  original value (0) instead of yielding 1, so the threshold never fires.
  `no_data_state = "OK"` keeps healthy (empty) results quiet.
- **Contact point / mute timing / message template**: add the matching
  resource, reference it from `grafana_notification_policy`.
- **Settings**: `grafana_organization_preferences` is a per-org singleton —
  do not add a second one.

## Adaptive Metrics

Adaptive Metrics analyzes how metrics are queried and recommends aggregations
that drop unused labels. `adaptive_metrics.tf` manages the tenant-wide
recommendations config: `keep_labels` (labels that must never be aggregated)
and `auto_apply` (whether Grafana Cloud applies the rest on its own).

The provider is pinned in `versions.tf`. It authenticates against the **hosted
Prometheus endpoint** with `<instance-id>:<access-policy-token>` — not the stack
URL and not the stack service-account token used by the `grafana` provider, so
it has its own `url`/`api_key` inputs (see Requirements above).

Policy:

- **`keep_labels`** lists the labels dashboards and alerts depend on. It only
  constrains *new* recommendations: a rule that already aggregates one of these
  labels stays as it is, so the list protects future queries, not existing ones.
- **`auto_apply.gate.policy = "no-increase"`** applies only recommendations
  whose net series change is zero or less. Auto-apply runs unattended, but a
  recommendation that would grow cardinality is skipped instead of applied.
  `unbounded` applies everything and needs a regular Rules-page review.

After apply, verify in Grafana Cloud → Adaptive Metrics: auto-apply is on for
the default segment (Overview/Segments), `keep_labels` is listed under
Exemptions, and Rules shows recommendations — the first ones appear within
~24h. Auto-apply is in public preview; while it is enabled no new custom rules
can be created (existing ones keep working).

The config is a tenant singleton: `create` only records it in state and
`delete` only forgets it, so the resource is not importable. A UI-side edit
shows up as drift on the next `terragrunt plan`: apply to overwrite it, or move
the change into `adaptive_metrics.tf`. If `plan` reports a permanent diff on
`auto_apply.gate` after a successful apply, the API is not echoing the gate
back — confirm with a `GET /aggregations/recommendations/config` before
treating it as a config error.

Add a per-metric `grafana-adaptive-metrics_exemption` only when the Rules page
shows a recommendation that auto-apply refused (or a metric that must keep full
cardinality); the `keep_labels` list already covers label-level protection.

## Caveats

- Resources created here are flagged **provisioned** in the Grafana UI: stop
  hand-editing them, or `terragrunt plan` reports drift.
- `grafana_notification_policy` **replaces the entire policy tree** on apply —
  it must always contain the full routing (root contact point + all nested
  policies).
- Free tier: one stack only; SLOs and stack-level settings are out of scope
  (they need a cloud access-policy token and the `grafana.cloud` provider
  block — possible follow-up).
- Alternative dashboard syncs: Grafana Cloud's Git Sync covers dashboards and
  folders only and is capped at 1 repo / 20 resources on the free tier — this
  unit is the full-coverage path.
