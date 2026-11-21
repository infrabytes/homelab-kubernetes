# OpenBao Operator (kubebao)

Kubernetes operator that owns the lifecycle of the `OpenBaoCluster` CR in
[`platform/openbao`](../openbao): provisioning, TLS, unseal wiring, backups,
upgrades and pod orchestration.

- Third-party project ([kubebao/openbao-operator](https://github.com/kubebao/openbao-operator)),
  **not** an official OpenBao project. Pre-GA: `v1alpha1` CRDs, minor releases
  may break the API, support is best-effort for the latest line.
- Chart: OCI `ghcr.io/kubebao/charts/openbao-operator`, Renovate-tracked via
  the `argocd` manager (docker datasource).
- `tenancy.mode: single` — controller-only runtime watching the `openbao`
  namespace; no provisioner. Fallback if a lifecycle feature (backup/upgrade
  Jobs) turns out to need multi-tenant mode: switch `tenancy.mode: multi` and
  add an `OpenBaoTenant` CR for the `openbao` namespace.
- Controller auth to OpenBao uses Kubernetes ServiceAccount JWTs
  (`controllerJWTMode: Target` on the cluster CR) — no static tokens.

Upgrade via Renovate PR: read the release notes before merging — pre-GA API
changes may require a coordinated update of the `OpenBaoCluster` CR.
