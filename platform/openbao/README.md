# OpenBao

Cluster secrets manager (CNCF sandbox, Vault fork), managed by the
**kubebao OpenBao Operator** ([platform/openbao-operator](../openbao-operator/))
instead of the Helm chart.

- `openbaocluster.yaml`: the `OpenBaoCluster` CR — HA raft (3 voters),
  Longhorn PVCs, operator-generated static seal key, operator-managed in-cluster
  TLS, Gateway exposure, NetworkPolicy, metrics. Renovate bumps `spec.version`.
- Everything **inside** OpenBao — auth methods, policies, Kubernetes-auth and
  OIDC roles, mounts, secret data, tenants — is Terraform:
  [`infra/openbao-config`](../../../infra/openbao-config/README.md), applied by
  Atlantis. Nothing here reconciles in-Bao state: self-init is one-time
  bootstrap, not continuous configuration.
- Companion manifests: `openbao-allow-gateway-ingress.yaml` (Cilium `ingress`
  entity — the CR's NetworkPolicy cannot name the host-network envoy) and
  `openbao-tailnet-ingress.yaml` (tailscale L7 exposure).

## What the operator gives us

- Self-init bootstrap: OpenBao initializes itself from the `selfInit.requests`
  list (admin policy, oidc auth + config via `dataFrom` of the `openbao-oidc`
  Secret, `sso-admin`/`sso-user` roles, kubernetes auth) and **revokes the
  bootstrap root token**. It stays limited to the human login path; the
  `secret/` kv-v2 mount and everything else inside Bao belongs to
  `infra/openbao-config` (a self-init enable would collide with the TF create
  at cutover). There is no root token anywhere; the one-time `bao operator
  init` + manual policy bootstrap is gone.
- Lifecycle: RollingUpdate rolls (Ready-gated, raft quorum kept — the old
  values-hack is now operator behavior), cert rotation, upgrade orchestration,
  immutable operator-generated seal key.

## Post-cutover trust model

- Secret **values** live in `infra/secrets.sops.yaml`; Terraform writes them
  with `vault_kv_secret_v2`. The repo (encrypted) and the Terraform state
  (pbkdf2-encrypted S3 backend on SeaweedFS) hold the values.
- Terraform authenticates via AppRole (`openbao-tf` role, `terraform` policy);
  `role_id`/`secret_id` in SOPS. This is the **one manual step** left after
  bootstrap: OIDC login as bbayrakt (`sso-admin`) → create the AppRole →
  `sops` the credentials.
- ESO reads via kubernetes auth (`eso-*` roles, one per consumer namespace),
  unchanged. ESO needs the operator CA per consumer namespace:
  `caProvider` in each SecretStore points at a copy of the
  `openbao-tls-ca` Secret (rotation period is 10y; if the CA rotates,
  re-copy it — command below).
- Human logins: OIDC via Authentik (`sso-admin` for bbayrakt, `sso-user`
  default, `sso-<tenant>` per tenant) — unchanged.

## Access

- LAN: https://bao.icaninto.space/ui → oidc (Gateway `openbao-https` listener;
  the operator renders the HTTPRoute; TLS terminated at the Gateway with the
  cert-manager DNS-01 cert, BackendTLSPolicy verifies the in-cluster backend).
- Tailnet: no dedicated hostname — tailnet devices reach
  https://bao.icaninto.space through the subnet router (the Connector
  advertises the gateway VIP). The old ts.net L7 Ingress was dropped: the
  operator reserves the `openbao` Ingress name for its own edge resources.
- ESO: `https://openbao-public.openbao.svc:8200` (the operator names the
  client Service `<cluster>-public`; the headless Service keeps `openbao`).
- Terraform/Atlantis: `https://bao.icaninto.space`.

## The in-cluster TLS Secret copies (one-time, per namespace)

The operator's CA lives in `openbao/openbao-tls-ca` (Secret, key `ca.crt`).
Every consumer namespace's SecretStore references a same-namespace copy:

```sh
for ns in arc-runners tailscale authentik velero alert-triage external-secrets-demo external-secrets pdeu factory; do
  kubectl -n openbao get secret openbao-tls-ca -o json \
    | jq '{apiVersion:"v1",kind:"Secret",metadata:{name:"openbao-tls-ca",namespace:"'"$ns"'"},type,type_:."type",data:.data}' \
    > /tmp/ca-copy.json
  kubectl apply -f /tmp/ca-copy.json
done
```

The cert is public material; the copies are refreshed only if the operator CA
rotates (`spec.tls.rotationPeriod`, currently 10y).

## Migration from the Helm chart (done once, 2026-11)

1. Lifted all kv values into `infra/secrets.sops.yaml` (via a pod login with
   the old `openbao-admin` k8s-auth role), then deleted the old chart
   release objects (StatefulSet, Services, PVCs, `openbao-seal` Secret).
2. ArgoCD installed the operator + the `OpenBaoCluster`; self-init ran,
   root token revoked.
3. One manual login (`sso-admin`) → AppRole `openbao-tf` → SOPS.
4. `atlantis apply infra/openbao-config`: mounts, policies, roles, secret
   data; ESO re-synced every consumer namespace.

## Recovery / break-glass

No root token exists. Break-glass is OpenBao's generate-root procedure with
the operator's unseal key (`openbao/openbao-unseal-key`) — the practical
recovery path is: recreate the cluster (the CR's `deletionPolicy: Retain`
keeps PVCs; a raft snapshot restore is `OpenBaoRestore`), then
`terragrunt apply` the openbao-config unit — the cutover itself proved that
path. Loss of the seal key = loss of the cluster's data; it lives in etcd
only, so the operator chain is: seal key → raft data, SOPS → values.
