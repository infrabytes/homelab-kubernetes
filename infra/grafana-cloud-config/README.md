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
    `adaptive-metrics-config:read`, `adaptive-metrics-config:write` and
    `adaptive-metrics-rules:read`. The portal exposes those for the config
    endpoint even though the
    [HTTP API docs](https://grafana.com/docs/grafana-cloud/adaptive-telemetry/adaptive-metrics/manage-as-code/adaptive-metrics-api/)
    name a non-grantable `adaptive-metrics-recommendations:write`. Rules read is
    not cosmetic: the provider fetches `GET /aggregations/segmented_rules` while
    configuring itself, so a config-only token without it fails every plan with
    `Could not initialize internal state. ... invalid scope requested`.
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
  constrains *new* recommendations: rules that already aggregate one of these
  labels stay as they are. Recommendations generated before a label joined the
  list keep proposing to drop it until the service regenerates them — when
  auto-apply was enabled, 82 of 160 pending recommendations still proposed
  dropping `pod`, `node`, `instance`, `namespace`, `container` or `job`, and
  those are applied anyway. That risk was accepted deliberately: Grafana only
  recommends aggregating labels it sees no queries for, so only queries built
  afterwards can read `<aggregated>`.
- **Auto-apply is on** (`auto_apply.enabled = true`). While it is on, no new
  custom rules can be created (existing ones keep working).
- **The `no-increase` gate is held server-side, not in HCL.** No released
  provider version has the `gate` attribute (0.3.3-0.3.6 have none; it exists
  only on the provider's unreleased `main`), and OpenTofu drops unrecognized
  keys inside a nested attribute object — so declaring it keeps
  `terragrunt validate` green while POSTing a config with **no gate at all**,
  i.e. ungated auto-apply that looks gated in review. Do not re-add the block
  until a release supports it, and confirm what actually landed with
  `terragrunt state show 'grafana-adaptive-metrics_recommendations_config.singleton'`
  rather than by reading HCL.

Every apply of this resource POSTs the whole config **without** `gate`, so the
gate is cleared whenever `keep_labels` or `auto_apply` changes. Re-set it right
after such an apply:

```sh
# reads the live config, forces auto-apply on with the gate, writes it back
curl -sS -u "$TENANT:$TOKEN" "$URL/aggregations/recommendations/config" \
  | jq '.auto_apply = {enabled: true, gate: {policy: "no-increase"}}' \
  | curl -sS -u "$TENANT:$TOKEN" -X POST -H 'Content-Type: application/json' \
      --data-binary @- "$URL/aggregations/recommendations/config"
```

`GET /aggregations/recommendations/config` echoes `auto_apply.gate` back when it
is set and omits it when it is not — that is the only reliable check, since
Terraform neither manages nor misses the gate. Renovate tracks the provider, so
the release that makes this declarable arrives as a PR.

The config is a tenant singleton: `create` only records it in state and
`delete` only forgets it, so the resource is not importable. A UI-side edit
shows up as drift on the next `terragrunt plan`: apply to overwrite it, or move
the change into `adaptive_metrics.tf`. A UI-side *gate* change is invisible to
`plan` — the provider has no such attribute — so only the API or the UI shows
it.

Add a per-metric `grafana-adaptive-metrics_exemption` to keep full cardinality
for a specific metric — that is the lever for the pending recommendations that
still propose dropping a kept label.

Auth note: the provider's `Configure` calls
`GET /aggregations/segmented_rules`, so the token needs
`adaptive-metrics-rules:read` even though this resource never touches rules.
After a policy change, Grafana Cloud propagates scopes unevenly across edge
nodes, so that call can intermittently return `401 invalid scope requested` for
a few minutes — retry before debugging the config.

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
