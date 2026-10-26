# OpenBao

Cluster secrets manager (CNCF sandbox, Vault fork). HA raft — 3 replicas, one
per worker — with Longhorn PVCs and the built-in static-key auto-unseal.

- Chart app: `application.yaml` (openbao/openbao `0.29.4`, Renovate-tracked).
- Namespace + seal-key Secret (`openbao-seal`): created by Terraform
  (`infra/addons/main.tf`) from `infra/secrets.sops.yaml` — keys never appear
  in manifests.
- LAN-only access: `route.yaml` in this folder (gateway `openbao-https` listener,
  cert-manager DNS-01 cert like argocd); plaintext http redirects to https
  (`redirect.yaml` in this folder). Tailnet access via the operator-managed L7
  Ingress (`openbao-tailnet-ingress.yaml` → `https://openbao.<tailnet>.ts.net`).
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
synced (`openbao` app Healthy in ArgoCD):

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

ESO (chart app `platform/external-secrets`) syncs Secrets from
OpenBao through **namespaced** `SecretStore`s: each consumer namespace has its
own store, ServiceAccount and OpenBao Kubernetes-auth role, read-scoped to a
single secret path. There is no cluster-wide store, so no namespace can read
another namespace's secrets.

| Namespace | Store | ServiceAccount | OpenBao role | Read scope |
|---|---|---|---|---|
| `arc-runners` | `openbao-arc-runners` | `arc-runners-eso` | `eso-arc-runners` | `secret/arc-runner-auth` |
| `tailscale` | `openbao-tailscale` | `tailscale-eso` | `eso-tailscale` | `secret/tailscale-operator` |
| `external-secrets-demo` | `openbao-demo` | `eso-demo` | `eso-demo` | `secret/demo` |
| `authentik` | `openbao-authentik` | `authentik-eso` | `eso-authentik` | `secret/authentik` |
| tenant namespace | `openbao-<tenant>` | `<tenant>-eso` | `eso-<tenant>` | `<tenant>/data/*` |

The chart renders all its CRDs. The two store CRDs' schemas exceed the 256KB
last-applied annotation limit, so the chart app injects a per-resource
`argocd.argoproj.io/sync-options: Replace=true` annotation (`crds.annotations`
in `platform/external-secrets/application.yaml`); ArgoCD then
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

### Declarative configuration

The ESO policies and roles, the tenant mounts, and the tenant policies/roles
are written by the chart's `server.postStart` hook on every pod start (the
same mechanism as the OIDC mount below) — no manual `bao policy write`
bootstrap for ESO and no root token: the hook logs in with Kubernetes auth as
the pod's own SA (`openbao-admin` role from the one-time Bootstrap above).

Seeding the consumer secrets stays manual (their values are not in git) — same
login inside the pod:

```sh
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200
  bao login -method=kubernetes role=openbao-admin jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
  bao kv put secret/arc-runner-auth github_token=<runner-pat>
  bao kv put secret/tailscale-operator client_id=<oauth-client-id> client_secret=<oauth-client-secret>
  bao kv put secret/demo demo-key=demo-value
'
```

Notes:

- A store sets the OpenBao provider `path` to the kv-v2 mount it may read
  (`secret` for the shared mount, `<tenant>` for tenant stores);
  `remoteRef.key` is relative to it (e.g. `arc-runner-auth`), and ESO
  appends the `/data/` suffix itself. Each role also carries the
  `sys/mounts/<path>` read that ESO's store validation (mount type/version
  check) needs.
- Every role is read-only and scoped to its own secret path; writes happen in
  OpenBao with a human or tenant token (`openbao-admin`, `sso-<tenant>`).
- ESO's OpenBao provider is read-only upstream (PushSecret is unsupported), so
  there are no PushSecret manifests: a secret is always created in OpenBao
  first and then synced down.

## Tenants

Tenant access is data-driven from `argocd/tenants/tenants.json` — one object
per tenant with a `members` list, each member carrying the **tailnet
identity** (the Kubernetes user the API-server proxy impersonates) and
optionally its **GitHub login** (for OpenBao SSO):

```json
{
  "tenant": "pdeu",
  "namespace": "pdeu",
  "members": [
    { "identity": "dhaustein@github", "user": "dhaustein" },
    { "identity": "alice@example.com" }
  ]
}
```

The two identities differ when a person did not sign into Tailscale with
GitHub (`name@github` is a Tailscale convention, not ours): RBAC uses
`identity`, while the OpenBao OIDC roles bind the Authentik username
(`preferred_username`, the same string as the GitHub login). A member without
`user` gets RBAC but no OpenBao SSO (they have no Authentik account). All
members of a tenant share
that tenant's access — namespace admin, cluster-wide read, full control of its
secret mount; there is no per-member separation.

- `argocd/appsets/tenants/applicationset.yaml` (git files generator,
  `goTemplate: true` — fasttemplate would stringify the nested members list)
  renders `charts/tenant-access` once per entry: RoleBinding to the built-in
  `admin` ClusterRole in the tenant namespace, ClusterRoleBinding to the
  built-in `view` ClusterRole cluster-wide (read-only, Secrets excluded), the
  ServiceAccount `<tenant>-eso` and the namespaced store `openbao-<tenant>`.
  Both bindings list every member as a subject.
- The `TENANTS="<tenant>:<namespace>[:<github-login>[|<login>]]"` marker in
  `platform/openbao/application.yaml` makes postStart enable the
  kv-v2 mount `<tenant>/` and write the `<tenant>-tenant` policy (full control
  of that mount), the `eso-<tenant>` policy (read `<tenant>/data/*`), the
  Kubernetes-auth role `eso-<tenant>` bound to `<tenant>-eso` in the tenant
  namespace, and `sso-<tenant>` on `auth/oidc` with
  `bound_claims.preferred_username` set to the tenant's GitHub logins.
  A tenant whose members have no GitHub login has its `sso-<tenant>` role
  deleted, so the marker stays the single source of truth.

The two lists must stay identical; the `tenant-config-check` pre-commit hook
compares them, shell-checks the postStart script and renders the chart. A
tenant name must also not collide with an existing mount: the hook rejects the
cluster/system mount names (`secret`, `sys`, `auth`, `identity`, `cubbyhole`,
`kubernetes`, `oidc`, `oidc-tailnet`), and postStart refuses to configure a
tenant path whose existing mount is not kv-v2.

### Onboarding a tenant

1. Add the entry to `argocd/tenants/tenants.json` (one `members` object per
   person: `identity` from the tailnet, `user` only for GitHub logins) and the
   same `tenant:namespace[:login[|login]]` triple to the `TENANTS` marker,
   then merge. On a from-scratch cluster the tenant Application can fail until
   its namespace exists (the tenant repo creates it) — re-sync it once it
   does.
2. The tenant logs in (`bao login -method=oidc role=sso-<tenant>`, from the
   LAN or a tailnet host, or through the OpenBao UI) and writes secrets into
   its own mount: `bao kv put <tenant>/<name> key=value`.
3. ESO syncs them with an ExternalSecret in the tenant namespace:
   `secretStoreRef: {name: openbao-<tenant>, kind: SecretStore}`,
   `remoteRef.key: <name>` (relative to `<tenant>/`). The ExternalSecret
   lives in the tenant's repo.
4. kubectl access as the member's tailnet identity (namespace admin +
   cluster read-only) goes through the Tailscale API-server proxy, which needs
   a tailnet ACL grant for that identity — Tailscale admin console, not this
   repo. The authoritative string is what the proxy sends; if it differs from
   the list, RBAC stays inert until `identity` is corrected.

### pdeu (dhaustein)

The first tenant: namespace `pdeu`, identity `dhaustein@github`, mount `pdeu/`,
store `openbao-pdeu`, role `sso-pdeu`. Open items on the tenant side:

- Tailnet ACL grant for `dhaustein@github` (without it the RBAC is inert).
- An ExternalSecret in `dhaustein/pdeu-discord-bot` pointing at
  `openbao-pdeu` (the cluster-wide store is gone).
- Moving the `pdeu-discord-bot-env` values into `pdeu/discord-bot`
  (`bao kv put pdeu/discord-bot ...`) so ESO can sync them down.

### Retired shared store (one-time cleanup)

Deleting `platform/external-secrets/` pruned the cluster-wide
`ClusterSecretStore openbao`. At the time the `platform` ApplicationSet generated
one Application per folder with Argo CD's
`resources-finalizer.argocd.argoproj.io` finalizer (nothing sets
`preserveResourcesOnDeletion`), so dropping the directory cascaded. The committed
app-of-apps Applications that replaced it set no finalizer, so a folder removal
there prunes only the Application and leaves the release's objects running.
Verify:

```sh
kubectl get clustersecretstore   # openbao must not be listed
```

The `eso-readonly` policy and the `external-secrets` Kubernetes-auth role
never lived in git (manual setup), so delete them once inside the pod:

```sh
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200
  bao login -method=kubernetes role=openbao-admin jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
  bao delete auth/kubernetes/role/external-secrets
  bao policy delete eso-readonly
'
```
```

## SSO (Authentik → OpenBao oidc auth)

Logins are served by Authentik ([`platform/authentik`](../authentik/README.md)),
which hosts the `openbao` OIDC provider; the issuer
`https://authentik.icaninto.space/application/o/openbao/` is the same for LAN,
tailnet and internet. One auth mount serves both entry points:

- `auth/oidc`: roles `sso-admin`/`sso-user` plus the tenant `sso-<tenant>`
  roles, each registering the LAN, the tailnet and the CLI redirect URI.

The retired `oidc-tailnet` mount (the former provider served one hostname per
issuer) is gone: Authentik serves LAN, tailnet and internet from one issuer,
and nothing configures the old mount any more.

### Roles

- `sso-admin`: bbayrakt (bound claim `preferred_username`) →
  root-equivalent `openbao-admin` policy.
- `sso-user`: any other Authentik account → `default` policy only (their own
  cubbyhole; every account exists only because it was created in Authentik,
  there is no self-signup).
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

The pods pin the issuer to the gateway VIP with `hostAliases`
(`authentik.icaninto.space` → `192.168.0.200`): the public record would send
their discovery, JWKS and token requests out through WAN to SWAG and back.
The Gateway authorizes such a request against the Authentik backend's identity,
so this pod's egress allow-list needs `openbao-allow-authentik-egress.yaml`
(the `ingress` entity, the VIP and a plain NetworkPolicy all get envoy's 403).

### Logging in

- Web UI: https://bao.icaninto.space/ui → sign in with method `oidc` →
  Authentik. bbayrakt: enter role `sso-admin`.
- CLI (LAN host): `bao login -method=oidc` (default role `sso-user`; as
  bbayrakt: `bao login -method=oidc role=sso-admin`; a tenant:
  `role=sso-<tenant>`).
- Tailnet: https://openbao.<tailnet>.ts.net/ui → the same method `oidc` and
  roles; the tailnet hostname's callback is registered on the same roles.

### Applying changes

The postStart script only runs at pod start. The StatefulSet uses
`updateStrategyType: RollingUpdate` (overriding the chart's `OnDelete`
default): a values/spec change rolls the pods one at a time, Ready-gated, so
raft quorum is preserved and no manual pod deletion is needed. To force a
restart of an unchanged spec (e.g. after updating a mounted Secret), run:

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
