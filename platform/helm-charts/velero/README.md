# Velero

Chart app `velero-app` (`vmware-tanzu/velero`, pinned `targetRevision`).
Namespace `velero`; the ESO-owned `cloud-credentials` Secret
(`platform/velero/`) feeds both the BSL credential ref and the node-agent's
`AWS_SHARED_CREDENTIALS_FILE`.

## Data path

kopia filesystem backup only (`snapshotsEnabled: false`, no CSI plugin, no
VolumeSnapshotClasses): the node-agent DaemonSet reads Longhorn volumes
directly. HostPath/secret/configmap volumes are skipped by Velero itself
(`GetVolumesByPod` in v1.18.2), so host-mounted DaemonSets (node-exporter,
alloy) need no exclude annotations. The aws plugin is not bundled in the
server image, hence the `velero-plugin-for-aws` init container.

The Schedule CR is named `velero-daily-all` (the chart prefixes the release
name) — that exact string is the `schedule` metric label the alert rules in
`platform/observability/alerting/infra-health.yaml` regex-match.

## Sizing (initial estimate 2026-09-27 — re-measure two weeks after cutover)

| Container | Requests | Limits | Why |
|---|---|---|---|
| velero server | 10m / 256Mi | 640Mi mem | orchestrates the backup; kopia dedup peak over ~5Gi of Longhorn data is bounded |
| node-agent (per node) | 50m / 64Mi | 256Mi mem | kopia hashing/compression runs here during the backup window |
| aws plugin init + CRD-upgrade hook | 10m / 32Mi | 48Mi mem | one-shot copy / `velero install --crds-only` |

No CPU limits (house style). Re-derive the memory pairs from VictoriaMetrics
p95 after two weeks of 03:30 runs.

## Decisions

- **grafana-pg filesets overlap CNPG barman — accepted.** Velero's kopia copy
  of the Grafana Postgres PVC is crash-consistent (no fsfreeze, no
  Postgres awareness), so it duplicates barman's stream rather than replacing
  it: **barman stays the point-in-time-recovery authority**, the Velero
  fileset is a coarser whole-volume fallback. Revisit only if CNPG ships a
  Velero-aware plugin.
- **nfs-nas excludes live in chart `podAnnotations`**, not a raw manifest:
  the vmsingle/Loki pods belong to other ArgoCD Applications, so a patch
  applied from `platform/velero/` would fight their `selfHeal`. Volume names
  are `server-volume` (vmsingle) and `storage` (Loki).
- **Dedicated bucket-scoped key**, not the state-bucket admin pair: the
  SeaweedFS policy for `velero_access_key` only reaches
  `homelab-kubernetes-backups`.
