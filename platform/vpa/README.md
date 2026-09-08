# VPA (recommendation-only)

Long-term pod CPU/memory usage history as the basis for setting
`resources.requests`/`limits` with confidence.

**What runs here:** the VPA recommender only, installed from the official
`vertical-pod-autoscaler` Helm chart (see `platform/helm-charts/vpa/` for the
chart Application: git source `kubernetes/autoscaler` at tag
`vertical-pod-autoscaler-1.7.1`, chart 0.9.0; the image 1.7.1 is pinned via
`recommender.image.tag` because the chart's `appVersion` lags its tags). Upstream
marks this chart "not ready for production use"; we accept that for the
recommender-only, report-only subset we use (no webhooks, no updater;
Service/ServiceMonitor stay as raw manifests). Updater and admission
controller are disabled in the chart values, so no pod is ever mutated or
evicted: every `VerticalPodAutoscaler` in this directory uses
`updateMode: Off` and only fills in `status.recommendation`. That guarantee
depends on `updater.enabled`/`admissionController.enabled` staying `false`. Grafana Cloud
keeps its role as the storage/trending source (metrics already collected:
`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`,
`kubelet_volume_stats_*`, `longhorn_volume_*`, plus the recommender's own
metrics via the ServiceMonitor in `servicemonitor.yaml`).

Why VPA in-cluster at all: Grafana Cloud's free tier retains metrics only 14
days. The recommender keeps its own per-VPA history (and
`VerticalPodAutoscalerCheckpoint` CRs, written periodically) inside the
cluster, so recommendations survive past any external retention window.

Layout split (chart vs. raw manifests):

- **Chart app** (`platform/helm-charts/vpa/application.yaml`) — the recommender
  Deployment, its ServiceAccount and RBAC, leader-locking Role/Binding
  (auto-created only when leader election is on; it stays off at
  `replicas: 1`), and the VPA CRDs: ArgoCD renders charts with
  `helm template --include-crds` by default, so the chart's `crds/` directory
  is applied as-is (VPA CRDs are ~44KB/10KB, well under the 256KB
  client-side-apply annotation limit). The chart ships no Service for the
  recommender.
- **Raw manifests** (`platform/vpa/`) — everything the chart does not render:
  the recommender `service.yaml` + `servicemonitor.yaml`, and the VPA objects
  themselves.

| File | Content |
| --- | --- |
| `service.yaml` | ClusterIP Service for the recommender's `:8942` /metrics endpoint (selector matches the chart's pod labels) |
| `servicemonitor.yaml` | ServiceMonitor for the recommender (scraped by alloy-metrics via `prometheusOperatorObjects`) |
| `vpa-*.yaml` | One file per namespace group; every VPA object is `updateMode: Off` |

Workloads covered: argo-cd (application-controller, server, repo-server,
applicationset-controller, dex-server, notifications-controller, redis),
cert-manager (all three Deployments), external-dns, Grafana Cloud stack
(`k8s-monitoring-alloy-metrics` StatefulSet, `k8s-monitoring-alloy-logs`,
`k8s-monitoring-kube-state-metrics`, `k8s-monitoring-node-exporter`; the
`k8s-monitoring-` prefix comes from the chart's release name and the
alloy-operator's subchart releases), hubble-observer (observer + cf2cnp
Deployments, namespace `hubble-observer`), kube-system (metrics-server,
`vertical-pod-autoscaler-recommender`, plus the Cilium/Hubble/CoreDNS
workloads (cilium, cilium-envoy, cilium-operator, coredns, hubble-relay),
which are deployed by `infra/cluster` via Terraform/Talos rather than
ArgoCD; the VPA objects are plain CRs and recommend regardless of who
deploys the target), kubelet-serving-cert-approver,
Longhorn (longhorn-manager, longhorn-driver-deployer, longhorn-ui,
longhorn-csi-plugin), spegel, vcluster, ARC controller (arc-systems), CloudNativePG operator (cnpg-system).

Deliberately not covered: ARC runner pods (StatefulSet generated at runtime
from the `AutoscalingRunnerSet`; runner resources belong in the
`gha-runner-scale-set` chart's `template.spec.resources` (see follow-up
below), Longhorn runtime workloads (engine-image `engine-image-ei-*`
DaemonSets and `InstanceManager` pods, both recreated per engine-image
version, plus the runtime-created `csi-attacher`/`csi-provisioner`/
`csi-resizer`/`csi-snapshotter` Deployments; resources are set via longhorn
settings/chart values), spegel's `spegel-cleanup` DaemonSet (helm post-delete
hook). Note: applying recommendations to the infra-deployed kube-system
workloads happens via the cluster unit's Cilium/Talos configuration
(env.hcl / infra/cluster), not via `platform/vpa/` manifests.

## Reading recommendations

```sh
kubectl get vpa -A                                  # all VPAs, one line each
kubectl get vpa -n <ns> <name> -o yaml              # full status
kubectl get vpa <name> -n <ns> -o jsonpath=          # just the numbers
  '{.status.recommendation.containerRecommendations}'
```

Every VPA `status.recommendation.containerRecommendations[]` carries
`lowerBound`, `target` and `upperBound` per container. The recommender
defaults (1.7.1, `pkg/recommender/config/config.go`) are: target = 90th
percentile (`--target-cpu-percentile` / `--target-memory-percentile`,
fractions `0.9`), lower bound = 50th percentile (`0.5`), upper bound =
95th percentile (`0.95`), all wrapped in a 15% safety margin
(`--recommendation-margin-fraction`); the upper bound additionally carries a
history-confidence factor. Practical reading:

- `lowerBound` — ~median usage + margin; the floor the updater would evict below (if one existed)
- `target` — the value to set as the request
- `upperBound` — ~95th percentile + margin + confidence; the ceiling the updater would evict above (if one existed)

With `updateMode: Off` and no updater deployed, all three values are
informational only; nothing acts on them. `kubectl get vpa -A` prints a
`Mode` column; `Off` means "report only".

**Timeline:** the recommender starts producing recommendations within hours,
as soon as enough usage samples accumulate (CPU before memory; memory uses
24h aggregation intervals), but treat them as stable only after ~8 days of
history (the default history length). It keeps aggregated history per VPA and
periodically writes `VerticalPodAutoscalerCheckpoint` CRs, so recommendations
survive restarts and, unlike Grafana Cloud metrics, are not bound by the
14-day free-tier retention.

## Upgrading

Renovate tracks the chart app's `targetRevision` (git tag); the chart's
`crds/` directory (and thus the VPA CRDs) ships with it, so a bump updates
chart templates and CRDs together. Nothing to regenerate by hand. In the
same change:

1. Reconcile `recommender.image.tag` in the chart app with the tag
   (the chart's `appVersion` lags its tags, so the image must be pinned
   explicitly).
2. Re-verify the recommender Deployment name/selector against a `helm
   template` render and update `service.yaml` / `vpa-kube-system.yaml` if the
   chart's naming changed.

Chart values notes: `podDisruptionBudget` is disabled because the chart
default (`minAvailable: 1`) would block node drains (e.g. `rolling-reboot.sh`)
with a single recommender replica. `containerSecurityContext` hardens the
recommender container (seccomp RuntimeDefault, no capabilities, read-only
root filesystem; the recommender writes nothing to disk, and checkpoints go
to the API server).

The CRDs are managed by the ArgoCD `vpa-app` chart app: removing the app
from git prunes the CRDs and **cascade-deletes every VPA and checkpoint CR**
(cluster-wide). Checkpoint CRs themselves are runtime-created and never
tracked by ArgoCD, so normal syncs never touch them.

## Storage sizing (not covered by VPA)

VPA does not cover PVCs. Sizing data is already in Grafana Cloud:

- **Fill ratio** per PVC (find PVCs approaching capacity):
  `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes`
  (or `kubelet_volume_stats_available_bytes`), filtered by
  `namespace`/`persistentvolumeclaim`/`instance` (node).
- **Longhorn volumes** (`longhorn_volume_*`, from the Longhorn ServiceMonitor):
  `longhorn_volume_actual_size_bytes` (replica size, incl. snapshots) vs.
  `longhorn_volume_capacity_bytes` (provisioned size), for snapshot-aware
  sizing decisions.

## Resource policy (requests/limits)

Workload resources are set from Grafana Cloud usage data with this policy (applied
Aug 2026; see the `feat/resource-requests` PR for the full table):

- **CPU: requests only, no limits.** CPU limits cause CFS throttling and
  provide no OOM protection; requests alone guarantee scheduling.
- **Memory: request + limit, limit = 1.5x request exactly.** Requests are
  the 14-day p95 of `container_memory_working_set_bytes` (1-minute
  granularity, via Grafana Cloud), rounded up, with a 32Mi floor; where the
  14-day max exceeds 1.5x the p95, the request is raised so the limit still
  covers the worst observed usage (no OOM regression vs. the previous
  no-limit state).
- The VPA objects stay `updateMode: Off` as a continuous drift monitor:
  when `status.recommendation` grows past the configured values, bump the
  resources in the chart values / manifests, not the VPA objects.

Where the values live: chart `Application` values under
`platform/helm-charts/` (argocd via `infra/addons/main.tf`), raw manifests
(`platform/metrics-server`, `platform/kubelet-serving-cert-approver`), and
the cluster unit for Cilium (`infra/cluster/cilium.tf`).

Known exceptions (not configurable / deliberately left):

- **coredns** (Talos bootstrap manifest): Talos machine config only supports
  `cluster.coreDNS.enabled`/`image`; the deployment keeps Talos's tuned
  defaults (100m/70Mi request, 170Mi limit).
- **longhorn-driver-deployer, longhorn-ui, pre-pull-share-manager-image**: the
  longhorn chart 1.12.1 exposes no resources for these (only
  `longhornManager.resources` and the
  `systemManagedCSIComponentsResourceLimits` setting).
- **ARC runner pods, Longhorn engine-image/InstanceManager/csi sidecar
  Deployments**: runtime-generated; resources belong in chart values/settings
  (see above), not here.

## Follow-up workflow

1. Size PVCs from the Grafana Cloud storage queries above.
2. ARC runners: set `template.spec.resources` in the
   `gha-runner-scale-set` Application values instead of a VPA (the runner
   StatefulSet is generated at runtime and cannot be targeted by a VPA).
