# Alert sandbox

Three sandboxed [pi](https://github.com/earendil-works/pi) agents run in namespace
`alert-triage`: two are fed by the Grafana webhook, the third by the Renovate gate.

**alert-triage** starts on every firing alert. The agent investigates with the read-only
Grafana MCP server and read-only `kubectl`, then posts a verdict to Discord: what fired,
whether it is actionable, the most likely root cause with the evidence behind it, and a
concrete fix suggestion. It never changes anything.

**memory-rightsize** starts on the two memory rules. The agent measures the container's
memory over 14 days, decides whether the request/limit should be raised, and opens a pull
request with the change (see [Memory rightsize](#memory-rightsize)).

**breaking-change** starts when Renovate adds the `needs-review` label to a minor or major
pull request (the bumps it does not automerge). The agent reads the upstream release notes,
checks this repository for usage of whatever changed, and posts one comment on the PR saying
whether it matters and what to do (see [Breaking-change review](#breaking-change-review)).

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
| `resource-quota.yaml` | at most 5 claims (sandboxes) at a time, across all three agents |
| `sandbox-template.yaml` | the sandbox: pi + kubectl, read-only SA, managed egress policy |
| `warm-pool.yaml` | zero-replica pool that supplies the template reference |

The Argo Events controller and its CRDs live in their own folder,
[`platform/argo-events/`](../argo-events/application.yaml): ArgoCD validates a whole
directory before applying it, so the chart Application cannot share a folder with the
`EventBus`/`EventSource`/`Sensor` objects whose CRDs it installs.
| `agent-config.yaml` | ConfigMap: `mcp.json`, triage contract (`APPEND_SYSTEM.md`), flap gate (`gate.mjs`), `entrypoint.sh`, `post.mjs` |
| `service-account.yaml`, `rbac.yaml` | sensor write scope (claims), agent read scope (`cluster-viewer`), and the `arc-runner` claim/log scope the gate workflow uses |
| `gate.test.mjs`, `rightsize-gate.test.mjs` | node fixtures for both gates; run by the `triage-gate-test` pre-commit hook |
| `secret-store.yaml`, `external-secret.yaml` | triage agent credentials from OpenBao |
| `memory-rightsize-sensor.yaml` | filters the two memory alertnames, creates one claim per alert |
| `memory-rightsize-sandbox-template.yaml` | the rightsize sandbox: pi + git + kubectl, read-only SA |
| `memory-rightsize-warm-pool.yaml` | zero-replica pool for that template |
| `memory-rightsize-agent-config.yaml` | ConfigMap: `mcp.json`, rightsize contract, `gate.mjs`, `entrypoint.sh`, `post.mjs` |
| `memory-rightsize-secret-store.yaml`, `memory-rightsize-external-secret.yaml` | the repository token, isolated from the triage store |
| `breaking-change-sandbox-template.yaml` | the analysis sandbox: pi + git, no cluster identity, DNS and 443 only |
| `breaking-change-warm-pool.yaml` | zero-replica pool for that template |
| `breaking-change-agent-config.yaml` | ConfigMap: the review contract and the entrypoint that prints the report |

## Credentials

Three values live in OpenBao at `secret/alert-triage` and reach the pods through the
`alert-triage-agent-creds` ExternalSecret (ESO-owned, refreshed hourly):

| Key | Used as |
| --- | --- |
| `llm_api_key` | `OPENCODE_API_KEY` (pi's built-in `opencode-go` provider) |
| `grafana_mcp_token` | `Authorization: Bearer …` for the Grafana MCP server |
| `discord_webhook_url` | the verdict destination |

The breaking-change sandbox reads only `llm_api_key`: it has no Grafana MCP token, no Discord
URL and no repository token, and the workflow that starts it posts the report.

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

The rightsize agent adds one credential of its own: a fine-grained GitHub PAT restricted to
this repository with `Contents: write` and `Pull requests: write`. It lives at
`secret/memory-rightsize` and reaches the sandbox as `GITHUB_TOKEN` through the
`memory-rightsize-agent-creds` ExternalSecret, so the triage identity cannot read it.

```sh
read -rs GH_PAT
bao kv put secret/memory-rightsize github_token="$GH_PAT"
```

Its policy (`eso-memory-rightsize`) and role are in the same openbao postStart script, so a
fresh value lands after the next OpenBao pod restart. The agent uses the models' key from
`secret/alert-triage`; rotating it rotates both agents.

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

## Memory rightsize

The `Container memory above 90% of limit` and `Container OOMKilled` rules start a second
agent from the same webhook: `Sensor memory-rightsize` filters those two alertnames, and the
memory route in `grafana-notification-policy.yaml` groups them per pod so one notification
carries one container. The agent measures 14 days of `container_memory_working_set_bytes`
through the Grafana MCP server, decides whether the working set justifies a bigger
request/limit or whether the series is a leak, and edits the owning manifest in a fresh
checkout of this repository. The sandbox pushes and opens the pull request itself.

```
memory alert ──► eventsource ──► Sensor memory-rightsize ──► SandboxClaim
                                                                 │
   gate (per-workload dedupe, context digest) ──> loki           │
   pi -p (headless) ──MCP──► grafana-mcp (metrics)               │
                     ──kubectl──► kube-apiserver (read-only)     │
                     ──edit──► /work/repo                        ▼
                              entrypoint: allowlisted diff → commit → push → GitHub PR
                                          │
                                          └─► Discord note (PR link, or why it declined)
```

The model never runs git. The entrypoint commits only `platform/`, `apps/` and `charts/` and
fails the run when the diff touches anything else — `infra/` in particular, where a PR is
auto-applied by Atlantis. The numbers follow the repo's sizing convention (memory request =
p95 rounded up to 64Mi with a 32Mi floor; limit = max(1.5x request, 1.25x peak); no CPU
limits), and the contract makes the agent decline when the series climbs without a plateau: a
bigger limit only buys time on a leak.

Dedupe is per workload, not per pod. Several replicas of one Deployment firing together
resolve to the same object, and the gate suppresses a run when this namespace logged a
`rightsize-record` for that workload inside `RIGHTSIZE_COOLDOWN` (7d) or when a `rightsize/*`
pull request is still open. Branches are `rightsize/<namespace>-<workload>-<YYYYMMDD>`, so the
first proposal of the day wins and a rerun after the merge gets a fresh branch.

A SKIP decision still posts to Discord and records itself, so a suspected leak stays visible
instead of being re-sized silently.

Running one by hand is the same claim, with the container spelled out:

```sh
kubectl -n alert-triage create -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: rightsize-manual-1
spec:
  warmPoolRef:
    name: memory-rightsize
  lifecycle:
    ttlSecondsAfterFinished: 600
    shutdownPolicy: Delete
  env:
    - name: ALERT_NAME
      value: Container memory above 90% of limit
    - name: ALERT_NS
      value: observability
    - name: ALERT_POD
      value: <pod>
    - name: ALERT_CONTAINER
      value: <container>
    - name: ALERT_JSON
      value: '{}'
EOF

kubectl -n alert-triage logs -f sandbox/rightsize-manual-1
```

## Breaking-change review

Renovate holds every minor and major bump for a human merge and labels it `needs-review`.
That label is the whole gate: nothing reads the release notes, so for the many dependencies
whose body only links to a changelog there is nothing to read. The sandbox answers the
question that actually decides the merge: does this break *this* repository.

```
PR labeled needs-review ──► breaking-change-analysis (homelab-runner)
                                          │ kubectl create
                                          ▼
                              SandboxClaim breaking-<pr>-<sha>
                                          │ cold start from
                                          ▼
                    SandboxTemplate breaking-change ─► Sandbox ─► Pod
                                                                     │
   pi -p ──curl──► api.github.com (PR body, changed files)           │
         ──curl──► upstream releases / changelog / compare diff      │
         ──grep──► /work/repo (shallow clone of main)                │
                              │ writes /work/report.md              │
                              ▼                                     ▼
            workflow reads the pod log → PR comment            claim deleted
```

The workflow, not the agent, owns the write: the sandbox holds no GitHub token and no
cluster identity, so the worst a prompt-injected changelog can do is produce a wrong
report. The runner's identity (`arc-runner`) is limited to claims and pod logs in this
namespace — `breaking-change-claim` in `rbac.yaml`. The report is one comment:

```
VERDICT: IMPACT | NO_IMPACT | UNKNOWN
WHAT CHANGED: ...
AFFECTS US: file:line, what breaks, the evidence
WHAT TO DO: the key and its new value, or "approve and merge" and why
```

`NO_IMPACT` has to name what was searched and checked; a changelog it could not read forces
`UNKNOWN` rather than a guess. Any failure posts a link to the workflow log instead, including
a claim that could not be created or a run that outlived its six-minute wait, so a red gate
never sits there unexplained.

One claim per PR *and* head SHA: a rebase supersedes the run (the workflow's concurrency
cancels it) and the new SHA gets its own claim, whose name also becomes the pod name. A
review event keeps the SHA, so it starts no new analysis. The claim is deleted when the job
ends; the TTL is the backstop for a cancelled job.

Running one by hand is the same claim, with the gate verdict spelled out:

```sh
kubectl -n alert-triage create -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: breaking-manual-1
spec:
  warmPoolRef:
    name: breaking-change
  lifecycle:
    ttlSecondsAfterFinished: 600
    shutdownPolicy: Delete
  env:
    - name: GITHUB_REPO
      value: infrabytes/homelab-kubernetes
    - name: PR_NUMBER
      value: "455"
    - name: REVIEW_REASON
      value: held for review (needs-review label)
EOF

kubectl -n alert-triage logs -f breaking-manual-1
```

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
- **Concurrency** — `ResourceQuota` caps claims at 5 across all three agents. One beyond
  that is rejected (sensor or workflow log), never queued; the claim TTL (5 min after the pod
  finishes) frees the slot.
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
cutover per the repo sizing convention. Limits are memory-only (no CPU limits). The
breaking-change sandbox carries the same provisional estimate from 2026-10-25.

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
  themselves are covered by each template's managed policy.
- No "Alert triage" dashboard panel yet; the pipeline is visible through pod logs and the
  failed-run rule only.
- Prompt injection through alert annotations is theoretically possible (labels/annotations
  reach the model). The blast radius is bounded by read-only RBAC and, for rightsize, an
  allowlisted diff — but keep alert annotations factual.
- Two replicas of one workload alerting within the same minute can race the rightsize gate.
  Both resolve to the same branch, so the second push (or PR) is rejected and only costs a
  Discord note; the 7-day record prevents the slow repeat.
