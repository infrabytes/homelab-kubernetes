# headlamp: in-cluster dashboard with per-user OIDC login

[Headlamp](https://headlamp.dev) (Kubernetes SIGs dashboard) served from the
cluster with **native OIDC login** against the LAN Dex. Every API request
carries the signed-in user's own identity — there is no shared dashboard
credential — and RBAC decides what each user sees.

## How it is wired

- Chart: `kubernetes-sigs/headlamp`, version pinned in `application.yaml`
  (Renovate-tracked via the `argocd` manager).
- Namespace + OIDC secret: the [addons unit](../../../infra/addons/README.md)
  owns the `headlamp` namespace and the `headlamp-oidc` Secret
  (`OIDC_CLIENT_ID`/`_CLIENT_SECRET`/`_ISSUER_URL`/`_SCOPES`, client secret
  from SOPS). `config.oidc.externalSecret` points the chart at it.
- Dex: a `headlamp` static client in `dex-config` (same addons unit) with
  redirect URIs for both public hostnames; Headlamp derives the callback from
  the request host.
- API server: trusts that issuer through the `KubeAuthenticationConfig`
  document in `infra/cluster` (audience `headlamp`, username claim
  `preferred_username`, prefix `oidc:`).
- Exposure: `route.yaml` + `redirect.yaml` on the LAN
  (https://headlamp.icaninto.space, `headlamp-https` gateway listener) and
  `tailnet-ingress.yaml` for https://headlamp.<tailnet>.ts.net.

## Login flow

1. Headlamp redirects to `https://dex.icaninto.space` (LAN DNS; the pod pins
   the gateway IP via `hostAliases`).
2. Dex authenticates the user through GitHub and the `infrabytes` org
   restriction, then returns an ID token whose `preferred_username` is the
   GitHub login.
3. Headlamp forwards the token to the API server, which validates it against
   Dex and treats the caller as `oidc:<github-login>`.
4. RBAC decides access: `rbac.yaml` binds per-user identities; a member with
   no binding can sign in but is denied everything.

The Headlamp ServiceAccount is deliberately bound to the read-only
`cluster-viewer` ClusterRole (the chart's `headlamp-admin` binding is
retargeted through values) — it only performs the in-cluster health checks,
never user requests.

## Users

One `ClusterRoleBinding` per member in `rbac.yaml`:

```yaml
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: oidc:<github-login>
```

Current bindings: `oidc:bbayrakt` → `cluster-admin`, `oidc:dhaustein` →
`cluster-viewer`. Group bindings are not possible: Dex's GitHub connector
emits no org-wide group claim (only `infrabytes:<team>`, and the org has no
teams). Push the change — ArgoCD applies it; no login is needed to verify with
`kubectl auth can-i get pods --as=oidc:<login>`.

## Remote (tailnet) access

`tailnet-ingress.yaml` serves the same pod at
`https://headlamp.<tailnet>.ts.net`. The login needs the LAN Dex too, so the
[subnet-router Connector](../tailscale-operator/connector.yaml) advertises only
the gateway VIP (`192.168.0.200/32`); approve that route in the Tailscale admin
console (and grant the tag ACL) once — see the
[tailscale-operator README](../tailscale-operator/README.md).

## Operations

- **Dex config changes need a pod roll.** Dex reads `dex-config` at container
  start and the chart's checksum annotation does not cover the external
  Secret, so after a change apply run
  `kubectl delete pod -n dex -l app.kubernetes.io/name=dex`; until then logins
  fail with an invalid-client error.
- **Dex down / restarted** blocks new Headlamp logins only. The API server
  keeps retrying OIDC discovery in the background; kubectl, ArgoCD and running
  workloads are unaffected. Dex keeps sessions in memory, so a roll logs
  existing Dex SSO sessions out (re-login).
- **Sizing** is a first estimate (2026-10-18, no usage history); re-measure
  after 2026-11-01 per the repo sizing convention.
- **NetworkPolicies**: default-deny ingress plus allows for the gateway
  (`fromEntities: ingress`), the tailnet proxy (namespace `tailscale`) and
  egress to DNS, the kube-apiserver and the dex pod on 5556. See
  [docs/network-policies.md](../../../docs/network-policies.md).
- **Observability follow-up**: Headlamp ships no metrics endpoint and no
  dashboard, so it is deliberately not scraped — revisit if upstream adds
  metrics (or derive login/audit signals from the kube-apiserver audit log).
