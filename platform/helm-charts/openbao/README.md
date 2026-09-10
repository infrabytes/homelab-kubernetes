# OpenBao

Cluster secrets manager (CNCF sandbox, Vault fork). HA raft — 3 replicas, one
per worker — with Longhorn PVCs and the built-in static-key auto-unseal.

- Chart app: `application.yaml` (openbao/openbao `0.29.4`, Renovate-tracked).
- Namespace + seal-key Secret (`openbao-seal`): created by Terraform
  (`infra/addons/main.tf`) from `infra/secrets.sops.yaml` — keys never appear
  in manifests.
- LAN-only access: `apps/openbao/route.yaml` (gateway `openbao-https` listener,
  cert-manager DNS-01 cert like argocd); plaintext http redirects to https
  (`apps/openbao/redirect.yaml`). Also exposed on the tailnet via Tailscale
  operator proxy (annotations on the `openbao-active` Service →
  `https://openbao.<tailnet>.ts.net`).
- Metrics: chart ServiceMonitor scraped by the k8s-monitoring stack.

## How auto-unseal works

`seal "static"` reads the 32-byte key from `/openbao/seal/current.key`
(file:// reference in the raft config; the Secret `current.key` holds the raw
bytes, TF decodes the base64 SOPS value). Every replica unseals itself on
start; the raft `retry_join` stanzas make followers join the cluster after
openbao-0 is initialized. No external unseal tooling.

Security tradeoff: any cluster-admin (or pod-exec) can read the seal key. This
is the accepted trust model — OpenBao chains to the cluster + SOPS as the
existing source of trust (static seal docs explicitly recommend this only when
such a source exists).

## Bootstrap (one-time)

Cluster must be reachable (`kubectl get nodes`), addons applied, and the chart
synced (`openbao-app` Healthy in ArgoCD):

```sh
kubectl port-forward -n openbao svc/openbao-active 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200

bao operator init -recovery-shares=0
#   OpenBao >= 2.4: no unseal keys (static seal), no recovery keys.
#   → JSON with the root token. If the CLI rejects 0 shares:
#   -recovery-shares=1 -recovery-threshold=1 and store the single recovery
#   key in SOPS too.
```

Store the root token in `infra/secrets.sops.yaml` (`openbao_root_token`, edit
via `sops`), then `cd infra && terragrunt apply --addons` so the value lands in
Terraform state (nothing in the cluster depends on it).

Then configure basics inside the cluster (root token stays there):

```sh
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<root-token>
  bao secrets enable -path=secret kv-v2
  bao policy write openbao-admin - <<'EOF'
path "*" { capabilities = ["create", "read", "update", "delete", "list", "patch", "sudo"] }
EOF
  bao auth enable kubernetes
  bao write auth/kubernetes/config \
    kubernetes_host=https://kubernetes.default.svc
  bao write auth/kubernetes/role/openbao-admin \
    bound_service_account_names=openbao \
    bound_service_account_namespaces=openbao \
    policies=openbao-admin \
    ttl=1h
'
```

Notes:

- No `token_reviewer_jwt` (and no `kubernetes_ca_cert`): OpenBao periodically
  re-reads the pod SA token file, so k8s auth keeps working across StatefulSet
  rolls (short-lived tokens) without config refresh. A stale pinned JWT would
  break every k8s-auth login after a roll.
- The `openbao-admin` role authenticates the OpenBao SA itself — the
  postStart SSO bootstrap (below) logs in with it. It is deliberately
  root-equivalent via the `openbao-admin` policy (single-admin homelab); the
  trust model already grants pod-exec seal-key access.
- The route is LAN-only; `bao.icaninto.space` resolves to the cluster gateway
  L2 IP (RFC1918). Keep the Cloudflare record DNS-only (proxying blocks
  RFC1918 origins).

## External Secrets Operator

ESO (chart app `platform/helm-charts/external-secrets`) syncs Secrets from
OpenBao. Stores: `ClusterSecretStore` `openbao` (cluster-wide) and a
namespaced `SecretStore` in the demo app (`apps/external-secrets-demo`); both
use Kubernetes auth as the ESO controller ServiceAccount
(`external-secrets`/`external-secrets`). Consumers: `arc-runner-auth`
(`apps/arc-runner-auth`, the ARC runner PAT, formerly created by the addons
unit from SOPS).

The chart renders all its CRDs. The two store CRDs' schemas exceed the 256KB
last-applied annotation limit, so the chart app injects a per-resource
`argocd.argoproj.io/sync-options: Replace=true` annotation (`crds.annotations`
in `platform/helm-charts/external-secrets/application.yaml`); ArgoCD then
creates them with `kubectl create` and updates them in place (PUT) — neither
adds the annotation. (ServerSideApply does not help: ArgoCD falls back to
client-side apply for CRDs.)

kubeconform: the store manifests are validated against vendored schemas in
`.kubeconform/external-secrets.io/` (generated from the chart CRDs, via a
local hook — the datreeio CRDs catalog is pinned to ESO 2.5.0, before the
`openBao` provider existed). On ESO chart upgrades, regenerate the vendored
schemas from the new chart CRDs (`bundle.yaml`, v1 versions, descriptions
stripped). Once the catalog's `external-secrets.io` update tracks an ESO
>= 2.7.0, the vendored schemas and the local hook can be dropped (revert to
the zrootorg kubeconform hook).

One-time setup (root token, as in Bootstrap):

```sh
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<root-token>
  bao policy write eso-readonly - <<EOF
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "sys/mounts/secret" {
  capabilities = ["read"]
}
EOF
  bao write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=eso-readonly \
    ttl=1h
  bao write auth/kubernetes/role/eso-demo \
    bound_service_account_names=eso-demo \
    bound_service_account_namespaces=external-secrets-demo \
    policies=eso-readonly \
    ttl=1h
  bao kv put secret/arc-runner-auth github_token=<runner-pat>
  bao kv put secret/tailscale-operator client_id=<oauth-client-id> client_secret=<oauth-client-secret>
  bao kv put secret/demo demo-key=demo-value
'
```

Notes:

- The stores set the OpenBao provider `path: secret` (the kv-v2 mount);
  `remoteRef.key` is relative to it (e.g. `arc-runner-auth`), and ESO
  appends the `/data/` suffix itself. The `sys/mounts/secret` read is for
  ESO's store validation (mount type/version check).
- The role is deliberately read-only on `secret/data/*`; write access stays
  with the root token / `openbao-admin` policy.

## GitHub SSO (Dex → OpenBao oidc auth)

Logins via GitHub are served by standalone Dex instances
([`platform/helm-charts/dex`](../dex/README.md)), restricted to the
`infrabytes` org. OpenBao has two OIDC auth mounts:

- `auth/oidc` (LAN): discovery URL `https://dex.icaninto.space`, roles
  `sso-admin`/`sso-user` with LAN redirect URIs.
- `auth/oidc-tailnet` (tailnet): discovery URL `https://dex.<tailnet>.ts.net`,
  roles `sso-admin`/`sso-user` with tailnet redirect URIs. Same static client
  credentials (`OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET`).

### LAN roles (`auth/oidc`)

- `sso-admin`: bbayrakt (bound claim `preferred_username`) →
  root-equivalent `openbao-admin` policy.
- `sso-user`: any other org member → `default` policy only (their own
  cubbyhole; org membership is enforced by the Dex GitHub connector).
- `auth/oidc/config.default_role = sso-user`, so the UI login is safe by
  default; bbayrakt selects the `sso-admin` role in the UI login form.

### How it's configured

The chart's `server.postStart` hook applies the mount, config, and roles on
**every pod start** (all 3 replicas, idempotent writes) — the chart's
mechanism for bootstrapping auth methods. It authenticates with Kubernetes
auth as the pod's own SA via the `openbao-admin` role above — **no root
token enters the cluster**. Client credentials come from the `openbao-oidc`
Secret (rendered by the [addons unit](../../../infra/addons/README.md)) via
`server.extraSecretEnvironmentVars`.

The hook exits 0 when the cluster is not yet initialized or the role does
not exist, so first boot stays quiet; once the roles exist, a config failure
fails the hook and the container restarts (visible crash loop, repairs on
the next start).

The pods reach both Dex instances via `hostAliases`: `dex.icaninto.space` → `192.168.0.200`
(the gateway L2 IP, DNS rebinding protection workaround) and `dex.<tailnet>.ts.net`
→ `10.111.254.10` (pinned cluster IP of the tailnet Dex Service).

### Logging in

- Web UI: https://bao.icaninto.space/ui → sign in with method `oidc` →
  GitHub. bbayrakt: enter role `sso-admin`.
- CLI (LAN host): `bao login -method=oidc` (default role `sso-user`; as
  bbayrakt: `bao login -method=oidc role=sso-admin`).
- Tailnet: https://openbao.<tailnet>.ts.net/ui → sign in with method
  `oidc-tailnet` → GitHub (through the tailnet Dex). bbayrakt: enter role
  `sso-admin`.

### Applying changes

The postStart script only runs at pod start: after the first bootstrap rolls
out the k8s-auth `openbao-admin` role (or after any postStart update), apply
the chart and run once:

```sh
kubectl rollout restart statefulset openbao
```

## Seal key rotation

Generate a new key, add it as a second Secret key and rotate via the static
seal's previous/current mechanism (docs:
<https://openbao.org/docs/configuration/seal/static/>):

1. `openssl rand -base64 32` → new SOPS value; add `previous.key` to the
   `openbao-seal` Secret with the old key (`binary_data` in `infra/addons`).
2. Config: `previous_key_id`/`previous_key` `file://` references alongside the
   new `current_key` (bump the `current_key_id`), then restart the StatefulSet.
3. Re-encrypt happens on restart; remove `previous_*` after a full seal cycle.
