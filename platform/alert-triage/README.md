# Alert triage Sandbox

Every Grafana alert that fires in this cluster starts a sandboxed [pi](https://github.com/earendil-works/pi)
agent. The agent investigates with the read-only Grafana MCP server and read-only
`kubectl`, then posts a verdict to Discord: what fired, whether it is actionable, the most
likely root cause with the evidence behind it, and a concrete fix suggestion. It never
changes anything.

```
Grafana alertmanager ──webhook POST /grafana (Bearer)──► EventSource grafana-alerts
                                                              │ NATS JetStream
                                                              ▼
                                                         Sensor alert-triage
                                                              │ create
                                                              ▼
                                         SandboxClaim triage-<alert-fingerprint>
                                                              │ cold start from
                                                              ▼
                                SandboxTemplate alert-triage ─► Sandbox ─► Pod
                                                                            │
   gate (flap check + memory digest, no model) ──> loki (own records)      │
   pi -p (headless) ──MCP──► grafana-mcp (metrics/logs/alerts/dashboards)    │
                     ──kubectl──► kube-apiserver (cluster-viewer, read-only) │
                     ──curl──► Discord webhook (verdict, ≤1900 chars)        │
                                                                            ▼
                      pod Succeeded → Sandbox Finished → claim TTL → claim + Sandbox GC'd
```

## Files

| File | Role |
| --- | --- |
| `event-bus.yaml` | NATS JetStream bus carrying webhook events to the sensor |
| `event-source.yaml` | webhook intake on port 12000, `/grafana`, bearer-token guarded |
| `sensor.yaml` | turns a firing notification into one `SandboxClaim` |
| `resource-quota.yaml` | at most 2 claims (sandboxes) at a time |
| `sandbox-template.yaml` | the sandbox: pi + kubectl, read-only SA, managed egress policy |
| `warm-pool.yaml` | zero-replica pool that supplies the template reference |

The Argo Events controller and its CRDs live in their own folder,
[`platform/argo-events/`](../argo-events/application.yaml): ArgoCD validates a whole
directory before applying it, so the chart Application cannot share a folder with the
`EventBus`/`EventSource`/`Sensor` objects whose CRDs it installs.
| `agent-config.yaml` | ConfigMap: `mcp.json`, triage contract (`APPEND_SYSTEM.md`), flap gate (`gate.mjs`), `entrypoint.sh`, `post.mjs` |
| `service-account.yaml`, `rbac.yaml` | sensor write scope (claims) and agent read scope (`cluster-viewer`) |
| `secret-store.yaml`, `external-secret.yaml` | agent credentials from OpenBao |

## Credentials

Three values live in OpenBao at `secret/alert-triage` and reach the pods through the
`alert-triage-agent-creds` ExternalSecret (ESO-owned, refreshed hourly):

| Key | Used as |
| --- | --- |
| `llm_api_key` | `OPENCODE_API_KEY` (pi's built-in `opencode-go` provider) |
| `grafana_mcp_token` | `Authorization: Bearer …` for the Grafana MCP server |
| `discord_webhook_url` | the verdict destination |

**Use a dedicated OpenCode Go key, not the host pi's key.** The agent runs unattended and
its spend should be attributable on its own: create the key in the OpenCode Console
(Account › Personal API keys, or — cleaner — a Service account under Settings › Service
accounts, which gets its own usage and budget) and give it `Models: Request` if you choose
Restricted permissions. Nothing in the manifests changes: the sandbox reads
`OPENCODE_API_KEY` from this Secret, so swapping the value is the whole rotation.

Seed all three (the MCP token and the Discord URL already exist in
`infra/secrets.sops.yaml` as `grafana_mcp_server_token` and `grafana_discord_webhook_url`).
Read the model key from stdin (`read -rs`) so it never lands in shell history:

```sh
# after the PR merged and the openbao pod restarted (it creates the policy + role)
read -rs TRIAGE_KEY
bao kv put secret/alert-triage \
  llm_api_key="$TRIAGE_KEY" \
  grafana_mcp_token="$(sops -d --extract '["grafana_mcp_server_token"]' infra/secrets.sops.yaml)" \
  discord_webhook_url="$(sops -d --extract '["grafana_discord_webhook_url"]' infra/secrets.sops.yaml)"
```

Rotate only the model key, leaving the other two untouched (KV v2 patch: one key, a new
version):

```sh
read -rs TRIAGE_KEY
bao kv patch secret/alert-triage llm_api_key="$TRIAGE_KEY"
```

In the UI the same edit is `secret/` → `alert-triage` → Edit. ESO refreshes the Secret
within an hour (`refreshInterval: 1h`), and a sandbox reads it only when it starts — a
running triage keeps the key it started with, so nothing needs restarting.

The policy only grants `read` on `secret/data/alert-triage`, so seeding and rotation use an
admin session (OIDC SSO or root), never the ESO identity.

A rotation takes effect on the next sandbox; nothing needs restarting inside the cluster.
The OpenBao policy (`eso-alert-triage`, read-only on that path) and its Kubernetes auth
role are configured by the openbao postStart script, so they are re-applied on every
OpenBao pod start.

The fourth credential, the webhook bearer token the Grafana contact point sends, is
Terraform-owned (`alert_triage_webhook_token` in SOPS → Secret `alert-triage-webhook`
here and a key in `grafana-notification-secrets` in `observability`). The Grafana operator
does not watch that Secret: after rotating it, touch the `GrafanaContactPoint` and delete
the eventsource pod.

The `alert-triage` namespace itself is Terraform-owned (`infra/addons`), like
`observability`: the webhook Secret has to exist before ArgoCD first syncs this folder.

## Running a triage by hand

```sh
kubectl -n alert-triage create -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: triage-manual-1
spec:
  warmPoolRef:
    name: alert-triage
  lifecycle:
    ttlSecondsAfterFinished: 600
    shutdownPolicy: Delete
  env:
    - name: ALERT_NAME
      value: Manual smoke test
    - name: ALERT_JSON
      value: '{"status":"firing","alerts":[{"labels":{"alertname":"Manual smoke test"}}]}'
EOF

kubectl -n alert-triage get sandboxclaim,sandbox,pods
kubectl -n alert-triage logs -f sandbox/triage-manual-1   # pi's transcript + report
```

The verdict lands in Discord; the full report stays in the pod log (Loki:
`{namespace="alert-triage"}`). A failed run prints `triage-failed: <reason>`.

## Behaviour and guardrails

- **Flap gate** — before any model call, `gate.mjs` reads this namespace's own Loki stream
  for a `triage-record` of the same alert fingerprint inside `TRIAGE_COOLDOWN` (2h). If the
  previous verdict was `NOISE` or `NO_ACTION`, the run is suppressed: one line
  (`triage-skip …`) is logged and the pod exits 0 without installing pi or calling a model
  (~4s, no tokens). An `ACTIONABLE` verdict instead re-arms the agent, which then re-checks
  whether the fix landed — and gets the earlier report attached. The gate fails **open**:
  if Loki is unreachable the analysis runs anyway (`triage-gate-degraded`).
- **Memory** — every run logs one `triage-record` line (fingerprint, alert, verdict,
  confidence, one-line cause, pod). The gate feeds the newest 6h of those records (every
  alert, not just this one), the cluster's warning/rollout events and the ArgoCD syncs in
  the same window into the prompt, so the agent can answer "is this the same issue again?",
  "did a deploy land right before it fired?" and "is another alert part of the same story?".
  For a recurrence it also pulls the previous report of the same claim (same pod name).
  Logs are the store: no database, no extra CRs, and Loki's 2160h retention is the horizon.
- **Name dedupe** — the claim is named `triage-<first 8 of the alert fingerprint>`, so a
  second notification while that claim still exists fails `AlreadyExists` and is only
  logged. This covers the minutes a run takes; the flap gate covers the hours after it.
- **Concurrency** — `ResourceQuota` caps claims at 2. A third simultaneous alert is
  rejected (sensor log), never queued; the claim TTL (5 min after the pod finishes) frees
  the slot.
- **Time** — `activeDeadlineSeconds: 1200` kills a stuck run; the pod then reports Failed
  and the claim is still collected by its TTL.
- **Knobs** (env on `sandbox-template.yaml`): `TRIAGE_COOLDOWN` (2h) and
  `TRIAGE_MEMORY_WINDOW` (6h).
- **Resolved notifications** are filtered out in the sensor (`body.status == firing`).
- **Read-only** — the agent's ServiceAccount is bound to the aggregated `cluster-viewer`
  ClusterRole plus a namespaced read on ArgoCD `applications` (`argocd`), which the
  aggregation does not cover and the memory digest needs; the Grafana MCP server runs with
  `--disable-write --disable-api` and a Viewer service account.
- **Cold start** on the analysis path is ~40-60s (image pull + the pinned pi release
  installed by `entrypoint.sh`); a suppressed flap costs only the pod start (~4s). A
  `SandboxWarmPool` with `replicas: 1`, or a prebuilt image, would remove the rest.

Choosing which alerts triage: the Grafana notification policy routes every alert to both
Discord and the `Triage` contact point. To opt a rule out, give it a label and add a
matcher to the `Triage` route — or silence it.

## Sizing

New workload (2026-10-18): requests are initial estimates, re-measured two weeks after
cutover per the repo sizing convention. Limits are memory-only (no CPU limits).

## Wiring gotchas (all hit on the first deploy)

- **The notification policy needs `continue: true`.** Alertmanager stops at the first
  matching sibling route, so the Discord catch-all in
  `platform/observability/grafana-notification-policy.yaml` must continue the walk; without
  triage silently never fires (Discord still works, so nothing looks broken).
- **`EventBus.spec.jetstream.streamConfig.replicas` must stay 1.** The controller merges the
  chart's `configs.jetstream.streamConfig` defaults into the bus on its first reconcile, so
  the value is pinned on the CR too. A single (non-clustered) NATS node rejects a
  multi-replica stream and the EventSource/Sensor crash-loop with
  `nats: replicas > 1 not supported in non-clustered mode`.
- **Webhook events are nested.** The EventSource publishes
  `{"header": …, "body": <payload>, "metadata": …}`, so the sensor's filter uses
  `body.status` and the trigger parameters use `.Input.body.alerts`.
- **Changes to the chart's eventbus config need a controller restart.** Adaptor deployments
  are generated from the EventBus status; after changing stream settings,
  `kubectl -n alert-triage rollout restart deploy/argo-events-controller-manager` regenerates
  them (deleting just the pods keeps the old env).
- **The Grafana contact point needs the eventsource Service to exist.** The URL is
  `grafana-alerts-eventsource-svc.alert-triage.svc.cluster.local:12000/grafana`, created by
  the EventSource CR — a missing EventBus (`eventBusName`) leaves the Service absent and
  every delivery fails.

- **`pod`/`container` are structured metadata in this Loki**, so they are returned with the
  stream but cannot be used as stream selectors: query them with a pipeline filter —
  `{namespace="alert-triage"} | pod="triage-<fp>"` — not `{namespace=…, pod=…}`. The gate's
  prior-report lookup depends on this.

## Known gaps


- The namespace is not in the phase-1 networkpolicy table; the eventing pods carry no
  policies yet (`docs/network-policies.md` lists the follow-up). The sandbox pods
  themselves are covered by the template's managed policy.
- No "Alert triage" dashboard panel yet; the pipeline is visible through pod logs and the
  `triage-failed` rule only.
- Prompt injection through alert annotations is theoretically possible (labels/annotations
  reach the model). The blast radius is bounded by read-only RBAC, but keep alert
  annotations factual.
