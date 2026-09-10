# dex: standalone Dex OIDC provider (OpenBao SSO)

A dedicated Dex instance that authenticates OpenBao logins via GitHub SSO
(`bao login -method=oidc` and the OpenBao UI). It is **independent** from the
Dex embedded in ArgoCD, runs in its own `dex` namespace, and is LAN-only at
https://dex.icaninto.space. A second Dex instance for the tailnet
(`dex-tailnet-app.yaml`, namespace `dex-tailnet`) serves remote SSO at
https://dex.<tailnet>.ts.net with its own GitHub OAuth app.

## What it is

- Chart: [dexidp/dex](https://dexidp.github.io/helm-charts), version pinned in
  `application.yaml` (Renovate-tracked via the `argocd` manager).
- Config: the `dex-config` Secret in the `dex` namespace, created by the
  [addons unit](../../../infra/addons/README.md) from SOPS variables
  (`dex_github_client_id`, `dex_github_client_secret`,
  `openbao_oidc_client_secret` in `infra/secrets.sops.yaml`). Values are
  injected through the chart's `configSecret` (`create: false`,
  `name: dex-config`); the chart never renders its own config.
- Exposure: Gateway route + http→https redirect under `apps/dex/`, TLS cert
  via the gateway's cluster-issuer annotation (same pattern as
  `apps/openbao/`). Cloudflare record via external-dns.
- `serviceMonitor.enabled: true` — the k8s-monitoring stack scrapes it.

## Config layout (`dex-config` Secret → `config.yaml`)

```yaml
issuer: https://dex.icaninto.space     # must match the public URL
storage: memory                        # stateless; config is static
web:
  http: 5556                           # chart Service port
connectors:
  - type: github
    id: github
    name: GitHub
    config:
      clientID: <SOPS>                 # "Dex (homelab)" OAuth app
      clientSecret: <SOPS>
      orgs: [{name: infrabytes}]       # org membership enforced by Dex
staticClients:
  - id: openbao
    name: OpenBao
    secret: <SOPS>                     # openbao_oidc_client_secret
    redirectURIs:
      - https://bao.icaninto.space/ui/vault/auth/oidc/oidc/callback
      - http://localhost:8250/oidc/callback   # `bao login -method=oidc`
oauth2:
  skipApprovalScreen: true
enablePasswordDB: false
```

## GitHub OAuth app

The connector uses a dedicated OAuth app (separate from ArgoCD's):

- GitHub → Settings → Developer settings → OAuth Apps → **Dex (homelab)**
- Authorization callback URL: `https://dex.icaninto.space/callback` (GitHub
  never fetches it; the LAN-only URL is fine)
- Request org access to `infrabytes` and approve it — without it the
  org-restricted connector rejects every login.
- Client ID/secret go into `infra/secrets.sops.yaml` as
  `dex_github_client_id` / `dex_github_client_secret`, then flow through the
  addons unit (no plaintext in git).

## Adding future clients / connectors

Edit the `dex-config` Secret source (the addons unit in `infra/addons/`
`main.tf`): add a `staticClients` entry (new client id/secret + redirect URIs)
or a connector, back it with a SOPS key, then `terragrunt apply` in
`infra/addons`. Dex picks up config changes at container start; ArgoCD
restarts the Deployment on Secret change (tracked resource in the chart).

## Verify

```sh
curl https://dex.icaninto.space/.well-known/openid-configuration   # from the LAN
```

Rotating a secret = rotate the SOPS key, apply addons, restart the Dex
Deployment.
