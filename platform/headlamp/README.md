# headlamp: in-cluster dashboard with per-user OIDC login

[Headlamp](https://headlamp.dev) (Kubernetes SIGs dashboard) served from the
cluster with **native OIDC login** against Authentik. Every API request
carries the signed-in user's own identity — there is no shared dashboard
credential — and RBAC decides what each user sees.

## How it is wired

- Chart: `kubernetes-sigs/headlamp`, version pinned in `application.yaml`
  (Renovate-tracked via the `argocd` manager).
- Namespace + OIDC secret: the [addons unit](../../../infra/addons/README.md)
  owns the `headlamp` namespace and the `headlamp-oidc` Secret
  (`OIDC_CLIENT_ID`/`_CLIENT_SECRET`/`_ISSUER_URL`/`_SCOPES`, client secret
  from SOPS). `config.oidc.externalSecret` points the chart at it.
- Authentik: the `headlamp` OAuth2 provider in
  [`platform/authentik/blueprints`](../authentik/README.md), client id
  `headlamp`, `sub_mode: user_username` (so `preferred_username` is the login
  and therefore the subject), redirect URIs for both public hostnames —
  Headlamp derives the callback from the request host. The issuer is
  `https://authentik.icaninto.space/application/o/headlamp/`; the client
  secret is the same SOPS value Authentik reads as
  `BLUEPRINT_OIDC_HEADLAMP_SECRET`.
- API server: trusts that issuer through the `KubeAuthenticationConfig`
  document in `infra/cluster` (audience `headlamp`, username claim
  `preferred_username`, prefix `oidc:`). The document's URL must match the
  discovery document exactly, trailing slash included.
- Exposure: `route.yaml` + `redirect.yaml` on the LAN
  (https://headlamp.icaninto.space, `headlamp-https` gateway listener) and
  `tailnet-ingress.yaml` for https://headlamp.<tailnet>.ts.net.

## Login flow

1. Headlamp redirects to
   `https://authentik.icaninto.space/application/o/headlamp/`. The pod pins
   the gateway VIP for that hostname via `hostAliases`, so its discovery and
   token requests stay on the LAN instead of going out through WAN to SWAG and
   back.
2. Authentik authenticates the user with their local account and TOTP.
   `sub_mode: user_username` makes `preferred_username` the account's login.
3. Headlamp forwards the token to the API server, which validates it against
   Authentik and treats the caller as `oidc:<login>`.
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
    name: oidc:<login>
```

Current bindings: `oidc:bbayrakt` → `cluster-admin`, `oidc:dhaustein` →
`cluster-viewer`. The bindings are per user; the shipped Authentik `profile`
mapping emits a `groups` claim, so a group binding can replace them later. Push
the change — ArgoCD applies it; no login is needed to verify with
`kubectl auth can-i get pods --as=oidc:<login>`.

## Remote (tailnet) access

`tailnet-ingress.yaml` serves the same pod at
`https://headlamp.<tailnet>.ts.net`. The login goes to the public Authentik
issuer, so a tailnet device needs internet access to it; the
[subnet-router Connector](../tailscale-operator/connector.yaml) advertises only
the gateway VIP (`192.168.0.200/32`) for the LAN-only UIs, not for this login.
Approve that route in the Tailscale admin console (and grant the tag ACL) once
— see the [tailscale-operator README](../tailscale-operator/README.md).

## Operations

- **Provider changes live in the Authentik blueprint.** The `headlamp` client
  (id, secret, redirect URIs, `sub_mode`) is owned by
  [`platform/authentik/blueprints`](../authentik/README.md); editing it rolls
  the Authentik worker through the ConfigMap checksum, and the provider is
  re-applied on the next blueprint run. Manual edits in the admin UI are
  reverted.
- **Authentik down** blocks new Headlamp logins only. The API server keeps
  retrying OIDC discovery in the background; kubectl, ArgoCD and running
  workloads are unaffected.
- **Sizing** is a first estimate (2026-10-18, no usage history); re-measure
  after 2026-11-01 per the repo sizing convention.
- **NetworkPolicies**: default-deny ingress plus allows for the gateway
  (`fromEntities: ingress`), the tailnet proxy (namespace `tailscale`) and
  egress to DNS, the kube-apiserver and the Authentik issuer: the gateway VIP
  on 443, plus the `authentik` server pods on 9000, without which the gateway
  denies the issuer with 403. See
  [docs/network-policies.md](../../../docs/network-policies.md).
- **Observability follow-up**: Headlamp ships no metrics endpoint and no
  dashboard, so it is deliberately not scraped — revisit if upstream adds
  metrics (or derive login/audit signals from the kube-apiserver audit log).
