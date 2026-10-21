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
   pi -p (headless) ──MCP──► grafana-mcp (metrics/logs/alerts/dashboards)    │
                     ──kubectl──► kube-apiserver (cluster-viewer, read-only) │
                     ──curl──► Discord webhook (verdict, ≤1900 chars)        │
                                                                            ▼
                      pod Succeeded → Sandbox Finished → claim TTL → claim + Sandbox GC'd
```

## Files

| File | Role |
| --- | --- |
| `application.yaml` | Argo Events chart (controller + CRDs), namespaced |
| `event-bus.yaml` | NATS JetStream bus carrying webhook events to the sensor |
| `event-source.yaml` | webhook intake on port 12000, `/grafana`, bearer-token guarded |
| `sensor.yaml` | turns a firing notification into one `SandboxClaim` |
| `resource-quota.yaml` | at most 2 claims (sandboxes) at a time |
| `sandbox-template.yaml` | the sandbox: pi + kubectl, read-only SA, managed egress policy |
| `warm-pool.yaml` | zero-replica pool that supplies the template reference |
| `agent-config.yaml` | ConfigMap: `mcp.json`, triage contract (`APPEND_SYSTEM.md`), `entrypoint.sh`, `post.mjs` |
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

Seed or rotate them (the MCP token and the Discord URL already exist in
`infra/secrets.sops.yaml` as `grafana_mcp_server_token` and
`grafana_discord_webhook_url`; the LLM key is the host pi's `opencode-go` key):

```sh
# after the PR merged and the openbao pod restarted (it creates the policy + role)
bao kv put secret/alert-triage \
  llm_api_key="$(pi auth print-api-key --provider opencode-go)" \
  grafana_mcp_token="$(sops -d --extract '["grafana_mcp_server_token"]' infra/secrets.sops.yaml)" \
  discord_webhook_url="$(sops -d --extract '["grafana_discord_webhook_url"]' infra/secrets.sops.yaml)"
```

The policy only grants `read` on `secret/data/alert-triage`, so the seed uses an admin
session (OIDC SSO or root), not the ESO identity.

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

- **Dedupe** — the claim is named `triage-<first 8 of the alert fingerprint>`. A repeat
  notification for the same alert while that claim still exists fails `AlreadyExists` and
  only logs a sensor error.
- **Concurrency** — `ResourceQuota` caps claims at 2. A third simultaneous alert is
  rejected (sensor log), never queued; the claim TTL (5 min after the pod finishes) frees
  the slot.
- **Time** — `activeDeadlineSeconds: 1200` kills a stuck run; the pod then reports Failed
  and the claim is still collected by its TTL.
- **Resolved notifications** are filtered out in the sensor (`body.status == firing`).
- **Read-only** — the agent's ServiceAccount is bound to the aggregated `cluster-viewer`
  ClusterRole; the Grafana MCP server runs with `--disable-write --disable-api` and a
  Viewer service account.
- **Cold start** is ~40-60s (npm install of the pinned pi release, image pull). A
  `SandboxWarmPool` with `replicas: 1`, or a prebuilt image, would make it seconds at a
  small idle cost.

Choosing which alerts triage: the Grafana notification policy routes every alert to both
Discord and the `Triage` contact point. To opt a rule out, give it a label and add a
matcher to the `Triage` route — or silence it.

## Sizing

New workload (2026-10-18): requests are initial estimates, re-measured two weeks after
cutover per the repo sizing convention. Limits are memory-only (no CPU limits).

## Known gaps

- The namespace is not in the phase-1 networkpolicy table; the eventing pods carry no
  policies yet (`docs/network-policies.md` lists the follow-up). The sandbox pods
  themselves are covered by the template's managed policy.
- Prompt injection through alert annotations is theoretically possible (labels/annotations
  reach the model). The blast radius is bounded by read-only RBAC, but keep alert
  annotations factual.
