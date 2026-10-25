# Homelab Kubernetes

GitOps-driven homelab Kubernetes cluster. A Talos Linux cluster (1 controlplane,
3 workers) runs on Proxmox VE; it is provisioned with Terragrunt + OpenTofu
(`infra/`) and applications are delivered by ArgoCD from this same repo
(`platform/` + `apps/`). Pushing to `main` deploys.

## Stack

| Component                    | Role                                                                 |
|------------------------------|----------------------------------------------------------------------|
| Talos Linux (v1.14.0)        | Immutable OS; machines built from Image Factory schematics (system extensions: intel-ucode, iscsi-tools, util-linux-tools) with static-IP kernel args |
| Kubernetes (1.37.0)          | Cluster on Proxmox VE (4 nodes), LAN 192.168.0.0/24                  |
| Terragrunt + OpenTofu        | Infrastructure provisioning: `cluster -> addons -> argocd-config`    |
| Cilium (1.20.1)              | CNI, kube-proxy-free, L2 LB (LB-IPAM 192.168.0.200-219), Gateway API (Gateway `homelab` at 192.168.0.200), WireGuard encryption, Hubble |
| Network policies             | Phase-1 namespace isolation for the chart-value workloads: chart values + per-namespace ingress default-deny + egress derived from Hubble flow audits, all co-located with their component under `platform/<component>/`; posture, verified gotchas and the phase-2 backlog in `docs/network-policies.md` |
| ArgoCD                       | GitOps delivery: one umbrella `platform` Application plus the `apps`/`pdeu`/`tenants` ApplicationSets, committed in `argocd/appsets/` and applied by a Terraform-managed bootstrap ApplicationSet; UI at argocd.icaninto.space |
| Atlantis (k3s)               | Terraform PR automation for `infra/**` (plan per unit, apply, squash-merge) in a single-node k3s cluster on the `windrunner` VM, registered in ArgoCD as cluster `windrunner` and deployed from `platform/atlantis/`; SWAG terminates TLS at atlantis.icaninto.space |
| SeaweedFS (k3s)              | S3 object store backing the Terragrunt state bucket, Velero and the Grafana/CNPG backups, in the same k3s cluster (`platform/seaweedfs/`): chart `allInOne` on a `local-path` PVC, `s3.icaninto.space` + `seaweedfs.icaninto.space` still fronted by SWAG; only the S3 and admin ports are NodePorts |
| cert-manager                 | TLS via Let's Encrypt DNS-01 (Cloudflare), ClusterIssuer `letsencrypt-dns01` |
| external-dns                 | Creates/updates Cloudflare DNS records from Gateways/HTTPRoutes      |
| OpenBao                      | Cluster secrets manager (Vault fork): HA raft (3 replicas, Longhorn), static-key auto-unseal, KV v2 + Kubernetes auth; UI at bao.icaninto.space (LAN only) |
| Authentik                    | Identity provider (`platform/authentik/`, namespace `authentik`) for every SSO client the cluster will move onto: local accounts only (no external OAuth source), TOTP enforced at first login, password reset by a Blueprint recovery flow over an SMTP relay, config-as-code from Blueprint ConfigMaps; own CloudNativePG database, secrets synced by ESO from OpenBao. LAN at authentik.icaninto.space, same issuer on the tailnet via the subnet-router Connector |
| Dex (standalone)             | Interim OIDC provider for OpenBao GitHub SSO (`sso-admin`/`sso-user` roles, org-restricted GitHub connector); LAN only at dex.icaninto.space — being replaced by Authentik, see `platform/authentik/README.md` |
| Headlamp                     | Kubernetes SIGs dashboard in its own `headlamp` namespace with **native OIDC login** against Dex: the API server trusts that issuer (Talos `KubeAuthenticationConfig`), so every request carries the user's own `oidc:<github-login>` identity and the per-user bindings in `platform/headlamp/rbac.yaml` decide access; the pod's ServiceAccount is read-only `cluster-viewer` instead of the chart's cluster-admin. LAN at headlamp.icaninto.space, tailnet via `headlamp.<tailnet>.ts.net` |
| Tailscale Operator            | Exposes cluster services on the tailnet (OpenBao UI, second Dex for remote SSO, Hubble UI, Headlamp) and provides in-process API server proxy for kubectl from tailnet devices; the `lan-subnet-router` Connector advertises only the gateway VIP (`192.168.0.200/32`, never the LAN subnet) so tailnet devices reach the LAN Dex for Headlamp's OIDC login |
| External Secrets Operator   | Syncs Secrets from OpenBao through per-consumer namespaced stores (k8s auth, one read-only role scoped to a single secret path each); e.g. the ARC runner PAT (`arc-runner-auth`) |
| Reloader                     | Rolls a pod when a ConfigMap/Secret it references changes, opt-in per workload (`reloader.stakater.com/auto`): velero + node-agent, tailscale operator, external-dns, dex + dex-tailnet, headlamp, grafana-mcp, openbao, and Grafana's datasource ConfigMap — rotating a credential no longer needs a manual `kubectl rollout restart` |
| Longhorn                     | Block storage on the worker nodes (dedicated disk labels); UI at longhorn.icaninto.space. Carries small state only (Grafana's Postgres cluster, ARC tool cache) — the observability TSDBs live on the NAS |
| csi-driver-nfs + `nfs-nas`   | NFS CSI driver and the `nfs-nas` StorageClass (NAS 192.168.0.22:/nas, Retain): the storage home for the VictoriaMetrics and Loki PVCs |
| Velero                       | Cluster backups: kopia fs-backup (no CSI snapshots) of k8s metadata + Longhorn PVC filesets to the SeaweedFS bucket `homelab-kubernetes-backups` (dedicated key via OpenBao/ESO); daily 03:30, 14d TTL; `emptyDir` + `nfs-nas` volumes excluded by the Velero resource policy; ServiceMonitor + two Grafana alert rules in `infra-health` |
| VictoriaMetrics + Loki       | Self-hosted observability stores in namespace `observability`: VictoriaMetrics single-node (metrics, 90-day retention) and Loki single binary (logs, filesystem TSDB v13, 2160h retention), both on `nfs-nas` PVCs |
| Grafana (OSS, local)         | Single Grafana instance managed by grafana-operator (namespace `observability`): datasources, folders, alert rules, contact point and notification policy are `platform/observability/` CRs; LAN at grafana.icaninto.space (Dex/GitHub SSO) and on the tailnet (Tailscale identity headers), both the same instance |
| Grafana MCP server           | Read-only mcp-grafana chart app (`platform/grafana-mcp/`, namespace `observability`) for MCP clients: Viewer-role service account, `--disable-write --disable-api`, caller bearer token on `/mcp`; LAN at grafana-mcp.icaninto.space — Pi reads dashboards, metrics, logs and alert rules through it |
| Grafana Cloud (free tier)    | Out-of-cluster watchdog only: the two `proxmox-maintenance` rules plus the `cluster-heartbeat` dead-man rule, notified to Discord; no cluster metrics/logs remote-write |
| grafana-operator             | Manages the local Grafana instance and delivers the chart-shipped dashboards from `platform/observability/dashboards/` (Cilium ×7 incl. the restored DNS Overview, Hubble flows, External Secrets, OpenBao), imported from the chart ConfigMaps (or the chart's OCI artifact) |
| Hubble Observer + CF2CNP     | Streams Cilium Hubble flows (DROPPED verdicts) to Loki; Grafana dashboard "Cilium Flows - Hubble Observer" (grafana.com #23862) on the local instance; CF2CNP web UI generates CiliumNetworkPolicies from flows at cf2cnp.icaninto.space |
| Hubble UI                    | Cilium's live service map (allowed vs dropped edges per namespace/workload), deployed standalone from the Cilium chart by ArgoCD in `kube-system`; exposed on the LAN at hubble.icaninto.space and on the tailnet as `hubble-ui`, both unauthenticated and neither public |
| Network Policies dashboard   | Grafana dashboard "Network Policies" on the local instance: endpoint enforcement status (`cilium_policy_endpoint_enforcement_status` = wide-open endpoints), policies per namespace and namespaces without any policy (KSM `kube_networkpolicy_*`), allowed-vs-denied flows and drop reasons (Hubble metrics); scraped through the `cilium-agent` PodMonitor |
| Node Exporter Full           | Host metrics for all four Talos nodes: the node-exporter DaemonSet is scraped by the k8s-monitoring Alloy into VictoriaMetrics (the chart allowlists unioned with 58 extra families, ~5.3k series); the vendored grafana.com #1860 "Node Exporter Full" (in-repo ConfigMap) renders in the Grafana Talos folder. The four PVE hosts run node_exporter too (the Debian `prometheus-node-exporter` package, installed by `ansible/proxmox-node-exporter.yml`) and are scraped by the same Alloy as job `pve-node`: the Talos nodes are QEMU guests with empty hwmon/powercap sysfs, so the dashboard's Hardware row (temps, RAPL package/DRAM watts via an added "Hardware Power (RAPL)" panel) only fills for the hypervisors |
| Container Logs dashboard     | Cluster-wide log triage on the local instance (Logs folder): log volume by namespace, error/warn rate from Loki's `detected_level`, top noisy pods, crash/kill events (`reason`) and a filterable log explorer; grafana.com #16976 rev 7 adapted to this cluster's labels (in-repo ConfigMap), with a pre-commit hook that executes every dashboard LogQL query against Loki |
| Kubernetes Views dashboards  | Upstream dotdc "Kubernetes / Views" suite on the local instance (Kubernetes folder): Global, Namespaces, Nodes and Pods views over the Alloy-scraped cAdvisor/kube-state-metrics/node-exporter series; grafana-operator imports grafana.com 15757-15760 by ID and re-resolves the newest revision each reconcile, and the k8s-monitoring allowlists were extended for the pod status/QoS, OOM/throttle and resource-count metrics the panels read |
| Dashboard alerts            | Grafana alert groups ported from the dashboards' upstream projects: the kubernetes-mixin workload/storage/node rules (`platform/observability/alerting/kubernetes.yaml`) and the adinhodovic/argo-cd-mixin rules (`platform/observability/alerting/argocd.yaml`); expressions stay upstream-verbatim minus the job/metrics_path matchers this cluster doesn't produce, and only firing series are returned, so the threshold evaluator fires on any result |
| GitHub Actions runners dashboard | In-repo dashboard (GitHub Actions folder) over the ARC listener/controller metrics: jobs and failures per workflow job, runner-minutes consumed per workflow, queue wait vs execution percentiles, pool desired/registered/busy/idle with saturation and queue depth, per-runner-pod CPU/memory/restarts/OOMs and controller reconcile health. Failure columns are summed as `failed or started*0` so a failure-free range keeps them. Runner job lines come from Loki; per-run links (run number, branch, SHA, conclusion) come from Grafana's GitHub data source (`platform/observability/grafana-github-datasource.yaml`, plugin installed through the CR's `plugins`, read-only PAT from SOPS) because ARC metrics carry no run id |
| ArgoCD dashboard            | Official ArgoCD example dashboard (`examples/dashboard.json`, pinned to the deployed ArgoCD version) on the local instance (ArgoCD folder): application health/sync overview, sync failures, reconciliation and kubectl performance, repo-server Git activity and component resources; imported from the argoproj repo URL, with the `datasource` variable pointed at VictoriaMetrics |
| spegel                       | Peer-to-peer container image distribution between nodes              |
| Agent Sandbox                | Sandboxed agent workloads (`agents.x-k8s.io` CRDs + controller, extensions enabled) from the upstream git-pinned Helm chart `v1.0.2`; ArgoCD-managed, metrics scraped into VictoriaMetrics |
| Alert triage                 | Every Grafana alert also starts a sandboxed pi agent (`platform/alert-triage/`, namespace `alert-triage`): Argo Events webhook intake → `SandboxClaim` → pi with the read-only Grafana MCP server and read-only `kubectl`, posting a verdict (actionable? root cause, suggested fix) to Discord; a Loki-backed flap gate (suppressed while the prior verdict was NOISE/NO_ACTION, re-armed after ACTIONABLE), a 6h memory digest (earlier triages, cluster events, ArgoCD syncs) in every prompt, 3-claim quota, 20-min deadline |
| Memory rightsize             | The two memory rules (90% of limit, OOMKilled) start a second sandbox from the same webhook (`platform/alert-triage/memory-rightsize-*.yaml`): pi measures 14d of `container_memory_working_set_bytes`, applies the repo sizing convention (request = p95 → 64Mi, limit = max(1.5x request, 1.25x peak)) and the sandbox opens a PR touching only `platform/`/`apps/`/`charts/`; declines (Discord note only) on leaks and other non-size problems, one proposal per workload per 7d |
| vCluster                     | Virtual Kubernetes cluster in namespace `vcluster`; hosts the PR-preview Argo CD used for diff rendering; access via `vcluster connect` |
| prometheus-operator-crds     | CRDs for the monitoring stack                                        |
| Actions Runner Controller    | Self-hosted GitHub Actions runners in-cluster (ARC), scale set `homelab-runner` |
| PR preview                   | Every same-repo PR touching `platform/`/`apps/` gets an Argo CD diff comment (`.github/workflows/pr-preview.yaml`): the diff is rendered by a dedicated Argo CD instance inside the vCluster (`argocd-preview`) and posted by `argocd-diff-preview` — the diff is the whole PR gate |
| Cluster viewer role          | View-only user `viewer@talos-cluster`: built-in `view` aggregation, Secrets fully excluded; kubeconfig generated by the `viewer-kubeconfig` unit (CSR API, no CA key extraction) |
| Tenant access framework      | Data-driven tenants (`argocd/tenants/tenants.json` → `tenants` ApplicationSet + `charts/tenant-access`): namespace admin + cluster-wide read-only RBAC, ESO identity and a namespaced OpenBao store; the OpenBao mount/policies/roles mirror the same list in the openbao postStart |
| SOPS + age                   | One encrypted secrets file (`infra/secrets.sops.yaml`), age key never in git |
| Renovate                     | Automated dependency bumps (versions in `infra/env.hcl`, chart `targetRevision`s, workflows), self-hosted from `.github/workflows/renovate.yaml` with a GitHub App token |

## Repository layout

```
infra/              Terragrunt/OpenTofu units: cluster -> viewer-kubeconfig, addons -> argocd-config
  env.hcl           ALL unit inputs centralized (versions, nodes, secrets)
  root.hcl          shared remote_state (S3 backend on SeaweedFS, pbkdf2-encrypted) +
                    artifact-sync hooks (kubeconfig/talosconfig <-> bucket `artifacts/` prefix)
  secrets.sops.yaml single SOPS-encrypted secrets file (never plaintext)
  scripts/          sync-artifacts.sh (Terragrunt hook script)
  cluster/          Talos cluster + Cilium; writes artifacts/kubeconfig + talosconfig,
                    and converges the rendered inline manifests on every apply
  viewer-kubeconfig/ Mints the view-only client cert + kubeconfig (CSR API, no CA key extraction)
  addons/           Installs ArgoCD, cert-manager, external-dns, OpenBao namespace + seal Secret, dex + dex-tailnet namespaces + config Secrets, headlamp namespace + OIDC Secret, ARC namespaces (runner PAT now synced by ESO from OpenBao)
  argocd-config/    ArgoCD bootstrap ApplicationSet (app-of-appsets)
argocd/appsets/     committed ApplicationSets (apps, pdeu, tenants) and the platform umbrella
                    Application, applied via the Terraform bootstrap ApplicationSet
argocd/tenants/     tenant list (source of truth for the tenants ApplicationSet + the
                    openbao postStart tenant config)
charts/             in-repo Helm charts rendered by ApplicationSets (tenant-access)
platform/           ArgoCD-managed cluster-level resources: one folder per
                    component holding the Helm chart Application plus its
                    companion manifests (namespace, ESO store/secret, routes,
                    network policies); e.g. velero/, openbao/,
                    tailscale-operator/, arc/, observability/, atlantis/
                    (Atlantis runs in the windrunner k3s cluster, registered
                    as a second ArgoCD destination)
apps/               ArgoCD-managed end-user applications (external-secrets-demo,
                    the ArgoCD HTTPRoute)
docs/               cross-cutting ops docs (network-policies.md)
hack/               laptop-side dev tooling; grafana-dev/ runs a disposable local Grafana
                    and exports authored dashboards into the ConfigMap-backed CRs
ansible/            rolling PVE host maintenance playbook (proxmox01-04) + windrunner
                    systemd units, plus windrunner-k3s.yml (k3s management
                    cluster + Atlantis bootstrap); see ansible/README.md
.github/            CI workflows + scripts (pre-commit, PR preview diff)
.pre-commit-config.yaml  the single lint/format gate
renovate.json       dependency automation
```

## External apps (pdeu)

`argocd/appsets/pdeu/` onboards `github.com/dhaustein/pdeu-discord-bot` as a
externally-managed application, fully GitOps: the directory carries the `pdeu`
AppProject (namespace `pdeu` only, that one repo as source, no cluster-scoped
resources), the `pdeu` Namespace itself, and an ApplicationSet whose git
directory generator watches the repo's `deploy/` folder on `main` and
auto-syncs it into namespace `pdeu`. The generator yields no applications
until a `deploy/` folder is pushed to the repo's `main` branch; when it is,
the `pdeu-discord-bot` Application is generated and auto-synced.

## PR preview (vCluster)

Every same-repo PR touching `platform/**` or `apps/**` runs `.github/workflows/pr-preview.yaml`
on the self-hosted `homelab-runner` scale set:

1. **Diff:** `argocd-diff-preview` renders base vs. target through a dedicated
   Argo CD instance running inside the vCluster (namespace `argocd-preview`).
   The workflow installs that instance itself, idempotently, via
   `helm upgrade --install` (chart `argo-cd` from `argoproj.github.io/argo-helm`).
2. **Comment:** the rendered diff is posted as one PR comment. Render errors
   (bad values, missing chart, template errors) fail the check — the render
   gate is Argo CD's own rendering, so there is no helm-vs-kubectl divergence.

That is the entire gate: no preview deployment, no health checks. The former
vCluster deploy/health stage (per-app allowlist, CRD supply, Cloudflare token
copy, Healthy/Degraded report, cleanup job) was removed — it was noisy
(a vCluster diverges from the host: missing CRDs/namespaces, extra
integrations, stale ArgoCD state) and expensive to maintain for the signal it
produced. Coverage now: render errors in this workflow, raw-manifest schema
validation (kubeconform) and chart render success (check-argocd-apps.py) in
pre-commit, and human review of the diff. Runtime behavior (crashloops, image
errors, webhook rejections) is a post-merge concern: ArgoCD syncs on merge,
the local Grafana watches the result, rollback is a git revert. The workflow never
mutates the host cluster — host access is read-only (the `vcluster` namespace
secrets/workloads the runner needs to reach the vCluster); everything the
preview creates lives inside the vCluster and is cleaned up by
`argocd-diff-preview` itself.

The vCluster and its Argo CD stay installed for the next PR.

Runner pods keep their caches pod-local and hydrate them from a shared
Longhorn RWX seed volume (`gha-runner-tool-cache` PVC in `arc-runners`, from
`platform/arc/`):

- `local/` (emptyDir, `sizeLimit: 10Gi` — a pod exceeding it is evicted
  instead of silently eating node disk) — the pod's own working cache:
  `runner/`
  (`RUNNER_TOOL_CACHE` for `Azure/setup-kubectl`, `Azure/setup-helm`,
  `actions/setup-python` and `terraform-linters/setup-tflint`; kubectl must
  match `kubernetes_version` in `env.hcl`), `mise/` (`MISE_DATA_DIR` for
  `gruntwork-io/terragrunt-action`'s terragrunt/tofu installs) and
  `pre-commit/` (`PRE_COMMIT_HOME` hook environments).
- `seed/` (RWX volume) — tarballs of the warmed `runner`, `mise` and
  `pre-commit` (hook environments) trees, published by the
  `.github/workflows/warm-tool-cache.yaml` workflow (the only writer,
  atomic `tar` + `mv`). The warm workflow wipes the pod-local trees before
  rebuilding, so the seed is a pure function of the repo's current pins —
  setup actions and pre-commit never prune old versions, and without the
  wipe every Renovate pin/rev bump would accumulate in the seed forever
  (measured: 5.5 GB of dead hook envs, 1.45 GB seed). The terragrunt-action
  restores its own GitHub-cache snapshot of the mise tree (jdx/mise-action
  cache, not exposed as an input), so the warm workflow additionally rebuilds
  the mise installs from the pins after the action runs. At every pod start
  the runner command extracts them into the emptyDir (best-effort: a missing
  or torn archive means a cold start with downloads).

Caches are per-pod by design, so jobs run fully concurrent: setup actions
only ever write pod-local paths and never race each other on the shared
volume. The scale set runs `minRunners: 1` so one pod is always alive with
warm caches; extra pods scale up under backlog and hydrate in seconds. The
warming workflow runs nightly, on `workflow_dispatch`, and on pushes to its
own file, `pre-commit.yaml` or `.pre-commit-config.yaml` (Renovate version
bumps re-warm automatically).

These directories must be writable by the job user for the setup actions to
populate them, and the tool-cache actions trust cache hits without
verification. Job code could plant a fake kubectl/helm/tflint there that
later runs would execute. Accepted trade-off for a homelab with trusted PR
authors: code running in a PR's own job already has the same-run exposure
(runner SA token, vcluster kubeconfig).

`pre-commit.yaml` runs on this self-hosted runner (like `pr-preview.yaml`),
so the warmed tools are consumed by every push and same-repo PR. Fork PRs skip
both jobs: the trade-off above assumes trusted PR authors, and `pre-commit`
executes the PR's own hook config. PR runs are diff-scoped
(`pre-commit run --from-ref <base> --to-ref HEAD` — only files changed by the
PR are checked, so a docs-only PR skips the chart renders and tflint/kubeconform
passes); pushes to `main` always run the full `--all-files` sweep, as do PRs
whose diff touches hook config (`.pre-commit-config.yaml`, `.yamllint.yaml`,
`.secrets.baseline`, `infra/cluster/.tflint.hcl`, the local hook scripts). One
exception: kubeconform — `bmuschko/setup-kubeconform` cannot use the tool
cache (it always downloads), and we deliberately do not hand-download
binaries into the cache, so it stays uncached (~5 MB per run, same cost as
before on `ubuntu-latest`).

The seed volume uses a dedicated StorageClass (`longhorn-rwx-cache`, see
`platform/arc/storage-class.yaml`) that tunes the NFS mount
options for cache-like data: `async` (writes acknowledged without waiting for
the server commit — the cache is disposable, so the small crash-loss risk is
acceptable), `noatime`, and 1 MiB `rsize`/`wsize`.

The CLIs without setup actions (vcluster, argocd-diff-preview, gh, kind) are
installed per-run by the PR preview workflow itself from its `*_VERSION` job
env pins (Renovate-tracked), so a bump is a single value and no cache warm-up
is needed.

Any workflow that later moves to the self-hosted runner just uses the same
setup actions; the warming workflow keeps the cache warm.

## Dependency automerge

Renovate automerges routine dependency PRs (see `renovate.json`): minor, patch
and digest updates merge themselves by squash once the release is at least
3 days old; major bumps never automerge. Infra PRs (`infra/**`) are the
exception — Atlantis is their sole merger (plan → apply → squash-merge,
apply-before-merge preserved), so Renovate never merges an infra PR.

Both automation paths are gated by the same two required checks on `main`:
`pre-commit` and `breaking-change-gate`. The gate
(`.github/workflows/renovate-gate.yaml`) is red for any Renovate PR
(`renovate[bot]` from the old hosted app, `infrabytes-renovate[bot]` from the
self-hosted workflow below)
that bumps a major version or whose release notes carry breaking-change
markers (`BREAKING CHANGE:` trailers, conventional `!:` commits, "breaking
change" mentions); a write-access approval turns it green and automation
resumes. Non-infra breaking PRs then need one manual merge click; infra PRs
flow apply → merge via Atlantis automatically.

Infra PRs get their apply comment on their own:
`.github/workflows/renovate-atlantis-apply.yaml` runs
`.github/scripts/renovate-atlantis-apply.py` when the `pre-commit` or
`renovate-gate` workflow completes and whenever a commit status changes on the
repository — the status trigger is what picks a PR up when Atlantis posts its
`atlantis/plan` status, which is usually the last gate to turn green. The
script comments `atlantis apply` on the head SHA — at most once per SHA — and
only when every commit status and check run on that SHA is green
(`breaking-change-gate` included) and Atlantis has posted a successful
`atlantis/plan` status for that same SHA. A *missing* `breaking-change-gate`
status also blocks the apply: the gate workflow exits 0 without posting one
when its status POST is rejected, and absence must not read as green.
The comment is authored by
`github-actions[bot]` with the workflow's `GITHUB_TOKEN`, adds no secret, and a
rebase or new push is evaluated afresh. Held major/breaking PRs stay
uncommented until an approval re-runs `renovate-gate` green.

One-time admin setup (idempotent, re-runnable):

```sh
gh api -X PATCH repos/infrabytes/homelab-kubernetes -F allow_squash_merge=true
gh api -X PUT repos/infrabytes/homelab-kubernetes/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": {"strict": false, "contexts": ["pre-commit", "breaking-change-gate"]},
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
```

`pre-commit` runs on the self-hosted runner, so a stalled runner stalls all
merges (required checks never complete); Renovate retries on later runs and
nothing is lost.

### Self-hosted Renovate

`.github/workflows/renovate.yaml` runs on `ubuntu-latest`:
`actions/create-github-app-token` mints a one-hour installation token for the
`infrabytes-renovate` GitHub App and `renovatebot/github-action` runs the engine
version pinned in `RENOVATE_VERSION` — the same release stream as the
`renovatebot/pre-commit-hooks` rev in `.pre-commit-config.yaml`, and one
`renovate` group bump moves both. Global config is env-only
(`RENOVATE_PLATFORM`, `RENOVATE_REPOSITORIES`), so `renovate.json` stays the
repository config instead of doubling as global config.

Triggers: `0 5 * * *` UTC as the baseline, `workflow_dispatch` for a run on
demand, `pre-commit`/`renovate-gate` completions on `renovate/*` branches, and
`issues`/`pull_request` `edited` events so ticking a Dependency Dashboard box
(matched by title) or a PR's "rebase/retry" box starts a run in seconds. The job
`if` narrows those edits to the dashboard and to `renovate/*` branches and
ignores the bot's own edits — Renovate rewrites both bodies on every run and an
App token's writes do fire workflow events. Renovate only manages dashboards it
authored itself (the issue query is filtered by author), so the self-hosted bot
creates its own dashboard rather than adopting the Mend-hosted one.

The `workflow_run` edge is what actually merges: Renovate merges only inside a
run, and a branch it just created or rebased is waiting on CI, so a later pass
does the merge. The cron cannot fill that role here, because GitHub's scheduler
runs hours late in this repo (`warm-tool-cache`'s `03:23` landed at 08:16-08:46
UTC on five consecutive days). The daily run is the backstop for discovering new
releases, not the merge path.

`prHourlyLimit: 0` in `renovate.json` compensates for the daily schedule: the
default of 2 would cap creation at ~2 PRs per day, while `prConcurrentLimit`
(10) still bounds open PRs. The `renovate` group rule turns
`minimumReleaseAge` off: only the pre-commit hook reports a release timestamp,
so the 3-day gate would hold the validator back while the image (no timestamp)
ran ahead, leaving the engine and its validator on different versions.

`prHourlyLimit: 0` in `renovate.json` compensates for the daily schedule: the
default of 2 would cap creation at ~2 PRs per day, while `prConcurrentLimit`
(10) still bounds open PRs. The `renovate` group rule turns
`minimumReleaseAge` off: only the pre-commit hook reports a release timestamp,
so the 3-day gate would hold the validator back while the image (no timestamp)
ran ahead, leaving the engine and its validator on different versions.

One-time setup (App creation is web-UI only; repository permissions
`Contents`, `Issues`, `Pull requests`, `Commit statuses` and `Checks` at
read+write, `Metadata: read`, and `Workflows: read+write` — the last is what
lets Renovate bump action pins inside `.github/workflows/**`. Renovate's docs
list more, but no administration, merge-queue, Dependabot-alert or
organization-members access is used here):

```sh
gh variable set RENOVATE_CLIENT_ID --body <app-client-id>
gh secret set RENOVATE_APP_PRIVATE_KEY < renovate-app.private-key.pem
gh workflow run renovate.yaml && gh run list -w renovate.yaml
```

The run needs no `GITHUB_TOKEN` permission: the App token does the writing, and
because it is an installation token the PRs it opens do trigger `pre-commit`
and `renovate-gate`, which a `GITHUB_TOKEN` PR would not. Uninstall the Mend
Renovate app once the self-hosted run is verified, so a single engine manages
branches — until then the old app keeps reading this repo's `renovate.json`
and can open branches under the same names. Renovate looks for its PRs with a
query filtered by author, so the new bot cannot see the old app's PRs at all:
tick their rebase boxes on the new dashboard **and close them**, or reusing
those branch names fails and the dashboard lists the updates as "Errored". The
legacy `renovate[bot]` login stays accepted by the gate and the apply script
until its PRs close.

## Getting started

### Prerequisites

- [Terragrunt](https://terragrunt.com/) and [OpenTofu](https://opentofu.org/)
- [talosctl](https://www.talos.dev/) (debugging and manual node operations;
  cluster upgrades are provider-driven)
- [sops](https://getsops.io/) + [age](https://github.com/FiloSottile/age) with the
  age key at `~/.config/sops/age/keys.txt` (or `SOPS_AGE_KEY_FILE`)
- Proxmox API token (bpg provider; see `infra/cluster/README.md` for required
  permissions)
- Cloudflare API token (DNS-01 certs + external-dns), set in
  `infra/secrets.sops.yaml`
- GitHub PAT (private repo access for ArgoCD) + GitHub OIDC client for ArgoCD
  SSO login (GitHub-only, org-restricted; the local admin and password login
  are disabled) + the `argocd_tf_token` for the Terraform provider, all in
  `infra/secrets.sops.yaml`

### Bootstrap

```sh
cd infra
terragrunt apply --all    # cluster -> viewer-kubeconfig, addons (ArgoCD, cert-manager, external-dns) -> argocd-config (bootstrap ApplicationSet)
```

The `argocd-config` unit creates a bootstrap ApplicationSet that applies the
committed `platform` Application and `apps` ApplicationSet from
`argocd/appsets/`. ArgoCD then syncs `platform/` and `apps/` automatically
(automated sync with prune + selfHeal).

### Day-2 workflows

Infra changes go through PRs: open a PR touching `infra/` (or an `env.hcl`
version bump) and [Atlantis](https://www.runatlantis.io) autoposts a
`terragrunt plan` per affected unit; when all plans succeed, Atlantis applies
and squash-merges the PR (`automerge`). Comment commands (`atlantis plan`,
`atlantis apply -d <unit>`) still work for targeted runs. Plans and applies are
ordered by each project's `execution_order_group` in `atlantis.yaml` (cluster,
then viewer-kubeconfig/addons, then argocd-config), so the terragrunt dependency
graph, `errors.retry` and `-parallelism=1` all hold; a failed group aborts the
later ones.

Manual runs still work from a host with the age key:

```sh
cd infra
terragrunt plan --all     # infra changes: nodes, versions, Talos/Cilium config
terragrunt apply --all    # apply them
```

App changes: edit `platform/` or `apps/`, push to `main`. ArgoCD deploys. PRs
touching `platform/` or `apps/` get a diff comment
(see [PR preview](#pr-preview-vcluster)).

Version bumps (Renovate PRs on the `env.hcl` pins) apply the same way:
`terragrunt apply --all` upgrades Talos nodes in place (drain → reboot,
controlplane first, workers one at a time) and rolls Kubernetes via Talos's
`upgrade-k8s` (see
[`infra/cluster/README.md`](infra/cluster/README.md#upgrades-talos--kubernetes)).

Pushes to this repo also trigger an instant ArgoCD app refresh via a GitHub
webhook (shared secret + payload cap; see
[`infra/addons/README.md`](infra/addons/README.md#argocd-github-webhook)),
and a second webhook drives Atlantis PR automation
(`atlantis.icaninto.space`, a Helm release in the k3s management cluster on
`windrunner` behind SWAG, see
[Atlantis management cluster](#atlantis-management-cluster-k3s)).

Secrets: edit `infra/secrets.sops.yaml` with `sops` (re-encrypts on save). The
age key is not in the repo; all units decrypt via `env.hcl`. Runtime secrets
for workloads are synced from OpenBao by External Secrets Operator (see
[`platform/openbao/README.md`](platform/openbao/README.md)).

Validation: `pre-commit run --all-files` (terragrunt fmt/validate/tflint,
yamllint, kubeconform, argocd-apps-check, ansible-lint, ansible-inventory-check,
detect-secrets, sops-encrypted, ruff, renovate-config-validator). CI runs the
same on push/PR.

### Atlantis management cluster (k3s)

Atlantis applies `infra/cluster` (Talos/k8s upgrades, Cilium, the Proxmox VMs),
so it does not live in the cluster it repairs. It runs in a single-node k3s
cluster on the `windrunner` VM (192.168.0.23), registered in ArgoCD as cluster
`windrunner` and deployed from `platform/atlantis/` (chart
`runatlantis/atlantis` pinned in that Application, namespace `atlantis`). That
is the only Application whose destination is not the Talos cluster.

What lives where:

- The chart's `initConfig` fetches terragrunt, sops and kubectl into `/plugins`
  (first on PATH) at every pod start; tofu is Atlantis's own download per
  `atlantis.yaml`. The server-side repo settings (formerly `repos.yaml` on the
  VM) are the chart's `repoConfig` value.
- `kubeconfig`/`talosconfig` reach each checkout from the state bucket
  (`infra/scripts/sync-artifacts.sh`, run by the Terragrunt hooks), so the old
  `pre_workflow_hooks` copy is gone.
- Credentials are not in git: the `atlantis-env` Secret in namespace `atlantis`
  holds `ATLANTIS_GH_USER`, `ATLANTIS_GH_TOKEN`, `ATLANTIS_GH_WEBHOOK_SECRET`,
  `ATLANTIS_API_SECRET` and `SOPS_AGE_KEY`, staged by the playbook from the
  VM's `~/appdata/atlantis/atlantis.env`.
- SWAG keeps terminating TLS: `atlantis.icaninto.space` proxies to the Atlantis
  NodePort 30414, so the GitHub webhook URL is unchanged.

Bootstrap, from a host with the Talos kubeconfig and the pinned collections
(`ansible-galaxy collection install -r ansible/requirements.yml`):

```sh
sops exec-env infra/secrets.sops.yaml \
  'ansible-playbook -i ansible/inventory.yml ansible/windrunner-k3s.yml --check --diff'
sops exec-env infra/secrets.sops.yaml \
  'ansible-playbook -i ansible/inventory.yml ansible/windrunner-k3s.yml'
kubectl --kubeconfig infra/cluster/artifacts/kubeconfig \
  apply -f ~/appdata/atlantis/cluster-windrunner.yaml  # written on windrunner
```

Re-runs are safe: they refresh `atlantis-env` after a GitHub token or age key
rotation and install k3s version bumps. Then merge the PR that touches
`platform/atlantis/`; ArgoCD creates the `atlantis` app and deploys the
release. Before the cutover, check the new instance on
`http://192.168.0.23:30414/healthz`, stop the old container (`docker compose
down` in `~/appdata/atlantis`), point `$upstream_port` in SWAG's
`site-confs/atlantis.conf` at `30414` and reload nginx. Rollback is the reverse
(`docker compose up`, port `4143`); the k3s side keeps nothing worth
preserving, so open PRs just need a fresh `atlantis plan`.

#### SeaweedFS

The same k3s cluster hosts the S3 store the repo depends on
(`platform/seaweedfs/`, chart `seaweedfs` pinned in that Application). Its
`allInOne` mode is the exact single `weed server -dir=/data -s3` process the
Docker container ran, now on a 100 Gi `local-path` PVC
(`seaweedfs-all-in-one-data`) with the `seaweedfs-admin` UI beside it. Only S3
(NodePort 30833) and the admin UI (32346) leave the pod network; SWAG keeps
the TLS certificates, the allowlist and both DNS names, so
`infra/root.hcl`, Velero and the CNPG backups keep using
`https://s3.icaninto.space/` unchanged.

The S3 identities are not in git: the playbook renders the
`seaweedfs-s3-config` Secret (key `seaweedfs_s3_config`, the `-s3.config`
file) from `infra/secrets.sops.yaml`, which is why it runs under
`sops exec-env`. SeaweedFS reads that file at start, so a key rotation needs a
`kubectl rollout restart deploy/seaweedfs-all-in-one` afterwards.

The release was cut over on 2026-10-24: the claim was seeded from the old
`~/appdata/seaweedfs/data` (a throwaway pod mounted the claim while the Docker
containers were stopped, `rsync -a` into the bound PV, then the pod was
deleted), and SWAG's `proxy-confs/s3.subdomain.conf` and
`seaweedfs.subdomain.conf` now point at `172.17.0.1` with ports 30833 and 32346.
That directory, both containers and their compose services are gone, so the
claim is the only copy of the buckets — rsync the PV directory off-host if they
should survive a windrunner reinstall.

### Dashboard authoring (grafana-dev sandbox)

Dashboards are authored against real data before they land in the repo.
`hack/grafana-dev/run.sh` starts a disposable Grafana on
`http://127.0.0.1:33000` with the production image (resolved from the live
Deployment), the production datasource names/UIDs pointed at port-forwarded
VictoriaMetrics and Loki, and every ConfigMap-backed dashboard preloaded.
After editing in the UI (Pi can drive it with the headless browser),
`./export-dashboard.py <uid> <dashboards-file.yaml>` writes the sandbox version
back into its ConfigMap and flips the `resyncPeriod` so grafana-operator
re-reads it; `./stop.sh` removes only what the sandbox started. See
[`hack/grafana-dev/README.md`](hack/grafana-dev/README.md).

Pi can also query the production stack directly through the read-only MCP
server at `https://grafana-mcp.icaninto.space/mcp` (caller bearer token; see
[`platform/grafana-mcp/README.md`](platform/grafana-mcp/README.md)).

### Alert triage

Alerts are not just announced: every notification also starts a triage sandbox
(`platform/alert-triage/`, namespace `alert-triage`). Grafana's alertmanager
posts the webhook to an Argo Events `EventSource`; the `Sensor` turns the
fingerprint into one `SandboxClaim`, which cold-starts a pi agent from
`SandboxTemplate/alert-triage`. The agent investigates with the read-only Grafana
MCP tools (metrics, Loki, alert rules, dashboards) and read-only `kubectl`
(`cluster-viewer`), then posts a verdict to Discord: `ACTIONABLE`/`NOISE`/
`NO_ACTION`, the evidence, the most likely root cause and a concrete fix. The
full report stays in the pod log (`{namespace="alert-triage"}` in Loki); a
`triage-failed:` line triggers its own Grafana rule.

Guardrails: claim names derive from the alert fingerprint (a re-fire while the
triage exists is skipped), a `ResourceQuota` holds at most three claims across both
agents, pods die at 20 minutes, and the claim (with its Sandbox) is collected five
minutes after the run finishes. Credentials live in OpenBao (`secret/alert-triage`) and
reach the pod through ESO; the webhook bearer token is Terraform-owned from SOPS.
See [`platform/alert-triage/README.md`](platform/alert-triage/README.md) for the
manifests, the secret layout and how to run a triage by hand.

### Memory rightsize

`Container memory above 90% of limit` and `Container OOMKilled` start a second agent
from the same webhook. It measures 14 days of the container's working set through the
MCP server, applies the repo's sizing convention, edits the owning manifest in a fresh
checkout and lets the sandbox push the branch and open the PR: one `rightsize/*` PR per
workload, deduped on the agent's own records (7 days) and on open PRs. When the series
climbs without a plateau the agent declines and says so on Discord — a bigger limit does
not fix a leak. The entrypoint commits only `platform/`, `apps/` and `charts/`, so a
rightsize PR can never trigger Atlantis; CI (pre-commit, the chart render check and the
PR diff) stays the gate before merge. The repository token is a fine-grained PAT at
`secret/memory-rightsize`, separate from the triage credentials.

### Cluster backups (Velero)

Velero (namespace `velero`, chart app in `platform/velero/`) keeps
one combined copy of the cluster: all namespaced and cluster-scoped resources
plus, via kopia filesystem backup, the Longhorn PVC filesets. The Schedule
`velero-daily-all` (note the chart's release-name prefix) runs daily at 03:30
into the SeaweedFS bucket `homelab-kubernetes-backups` with a 14-day TTL. There
is deliberately no CSI path: no snapshots, no VolumeSnapshotClasses, and the
aws credentials come from the ESO-owned `cloud-credentials` Secret (dedicated
bucket-scoped key from `secret/velero` in OpenBao — never the state-bucket
admin key).

The Velero server is cluster-internal only (nothing on a gateway); operations
run the `velero` CLI locally against the same kubeconfig as `kubectl`:

```sh
velero backup get                                   # list scheduled + manual backups
velero backup describe daily-all-<date> --details   # filesets: grafana-pg present, nfs-nas absent
velero backup logs daily-all-<date>                 # kopia upload log
velero backup create manual-<name> --from-schedule velero-daily-all  # run one now
velero restore create <name> --from-backup <backup> \
  --namespace-mapping <src-ns>:<scratch-ns>         # restore into a scratch namespace only
velero backup delete <backup>                       # prune early if needed
```

Restores always go to a scratch namespace via `--namespace-mapping` — never
over the original workload. Two caveats are accepted by design: the fileset
copies are crash-consistent (no fsfreeze), and for Grafana's Postgres
(`grafana-pg`, Longhorn) the CNPG barman object-store copy stays the
point-in-time-recovery authority — the Velero fileset is a second,
coarser-grained DR copy.

Standing convention: `nfs-nas` and `emptyDir` volumes stay out of the kopia
filesets, enforced by the Velero resource policy the schedule template
references — a new NAS-backed workload needs no per-pod annotation. Keep the
pod annotation `backup.velero.io/backup-volumes-excludes: <volume-name>` for
one-off exclusions the policy can't infer (vmsingle and Loki still carry it
as belt & braces; see
[`platform/velero/README.md`](platform/velero/README.md)).

### PVE host maintenance

The four PVE hosts are patched automatically every Sunday 04:00
(Europe/Vienna) by the Ansible playbook in [`ansible/`](ansible/README.md),
run from the windrunner systemd timer: one host at a time (workers first with
cordon + drain, `proxmox01` last with a graceful VM shutdown only — expect
~2-5 min without the Kubernetes API during its reboot), reboots only when
required, waits for the Talos node and all Longhorn volumes to be healthy
before the next host, and reports per-host lines to Grafana Cloud Loki
(`job="proxmox-node-updates"`; failed-run + 8-day dead-man alerts live in
`infra/grafana-cloud-config/maintenance_alerts.tf`). Manual dry run and
single-host canary commands are in
[`ansible/README.md`](ansible/README.md#commands).

## Further reading

- [`infra/README.md`](infra/README.md): Terragrunt workflow, SOPS/age, unit ordering, view-only cluster access (`viewer@talos-cluster` kubeconfig)
- [`infra/cluster/README.md`](infra/cluster/README.md): Talos provisioning, Cilium inline manifest, networking, upgrades
- [`infra/addons/README.md`](infra/addons/README.md): ArgoCD bootstrap, adding apps
- [`infra/argocd-config/README.md`](infra/argocd-config/README.md): bootstrap ApplicationSet
- [`AGENTS.md`](AGENTS.md): guidance for AI coding agents working in this repo
