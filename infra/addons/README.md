# addons: ArgoCD GitOps bootstrap

Installs ArgoCD and the GitOps scaffolding after the Talos cluster exists.

## What it manages

### **ArgoCD**

ClusterIP only; no LB, the Cilium Gateway fronts it  (`server.insecure` so ArgoCD
serves plain HTTP behind the Gateway's TLS). Installs the ApplicationSet CRD +
controller.

### **ArgoCD authentication (SSO-only)**

Login is exclusively via **Authentik OIDC** (client id `argocd`, PKCE); no
username/password login is offered. `argocd-cm` carries the `oidc.config`
block and `argocd-secret` the matching `oidc.clientSecret`
(`authentik_argocd_client_secret` from SOPS). The issuer name is LAN-only, so
the chart's `global.hostAliases` pins `authentik.icaninto.space` to the VIP for
the server's discovery, JWKS and token calls. The local `admin` account
is disabled (`configs.cm."admin.enabled" = "false"`) and the only local account,
`tf-bot`, has the `apiKey` capability (token generation) but **not** `login` —
so the ArgoCD login page shows SSO only (ArgoCD hides the password form when no
enabled account has the `login` capability).

The chart's embedded Dex is disabled (`dex.enabled = false`). ArgoCD v3.5 attaches
its `DexRewriteURLRoundTripper` to the OIDC verifier whenever `dex.config` is set,
without the `OIDCConfigRAW == ""` guard the login client has
(`util/session/sessionmanager.go:170` vs `util/oidc/oidc.go:264`): the verifier
then fetches Dex's JWKS instead of Authentik's and rejects every Authentik ID
token on the signature check. Re-enable Dex only after upstream fixes it. The
GitHub OAuth app the old Dex connector used is no longer needed; the repo webhook
below is unrelated to login.

- RBAC is configured in `../env.hcl` (`addons.argocd_rbac`): `policy.default`,
  the OIDC `scopes`, and the `policy.csv` lines (any ArgoCD RBAC syntax —
  users, roles, project-scoped grants). The unit only prepends the mandatory
  `p, tf-bot, *, *, *, allow` line (the argocd-config provider authenticates
  as `tf-bot`, so it must always be allowed; a role binding would also match
  any SSO scope named `tf-bot`, per the RBAC docs).
- The admin password is still set deterministically on the chart
  (`configs.secret.argocdServerAdminPassword`, a bcrypt of the SOPS plaintext)
  so the argocd provider in `../argocd-config` can bootstrap before SSO
  variables exist, but the account is disabled once `argocd_tf_token` is set.
- **`argocd_tf_token`**: long-lived API token for `tf-bot`, generated with
  `argocd account generate-token --account tf-bot` (while admin login still
  works, i.e. before the token is stored in SOPS). Stored in
  `../secrets.sops.yaml`. When it's set, the `admin.enabled=false` flip is
  applied and the argocd provider switches to token auth; while it's empty the
  provider falls back to the admin password (fresh bootstrap).

### **ArgoCD GitHub webhook**

The API server accepts GitHub webhook events at
`https://argocd.icaninto.space/api/webhook`, so a push to the gitops repo (or
any other repo with a webhook pointing there) refreshes the matching
Applications within seconds instead of waiting for the 3-minute poll.

- **Shared secret** (required, the endpoint is publicly reachable):
  `argocd_webhook_secret` (SOPS) is written into `argocd-secret` as
  `webhook.github.secret` by this unit. GitHub signs every delivery with
  `X-Hub-Signature-256`; ArgoCD rejects events with an invalid signature
  (HTTP 401). Without a secret configured ArgoCD would still accept
  unauthenticated events (they only trigger a refresh, but are an open
  DDoS/refresh-flood surface).
- **Payload cap**: `webhook.maxPayloadSizeMB = "1"` in `argocd-cm` — the
  `/api/webhook` endpoint has no rate limiting, so request bodies are capped
  well below the 50MB default (DDoS hardening; GitHub push payloads carry only
  commit metadata and stay far below 1MB).

GitHub side (repo → Settings → Webhooks → Add webhook):

1. Payload URL: `https://argocd.icaninto.space/api/webhook`
2. Content type: `application/json` (`x-www-form-urlencoded` is not supported
   by the webhook library)
3. Secret: the `argocd_webhook_secret` value from SOPS
4. Events: *Pushes* (or "Let me select individual events")

Rotating the secret: set the new value in SOPS (`argocd_webhook_secret`), apply
this unit, then paste the same value into the GitHub webhook. The API server
picks up the secret change automatically (no pod restart).

Note: the committed `platform` Application and the `apps`/`pdeu` ApplicationSets
also refresh instantly on pushes to their repos (the API-server webhook matches
on `repoURL`), so a new `platform/<name>/` folder is picked up right away. Only
new directories under `apps/` (the ApplicationSet git generator) wait for the
3-minute poll — the ApplicationSet controller exposes a separate webhook server
that would need its own hostname + HTTPRoute, which is not set up.

### **Component namespaces and bootstrap Secrets**

Terraform owns the namespaces and Secrets that must exist before ArgoCD (or
before a chart that reads them) can run: a from-scratch bootstrap applies this
unit before ArgoCD exists, so an ArgoCD-owned namespace would fail the apply.

- `openbao` — namespace + the `openbao-seal` Secret (static seal key).
- `headlamp` — namespace + the `headlamp-oidc` Secret
  (`OIDC_CLIENT_ID`/`_CLIENT_SECRET`/`_ISSUER_URL`/`_SCOPES`, client secret from
  SOPS) that the Headlamp chart reads via `config.oidc.externalSecret`. See
  [`platform/headlamp`](../../platform/headlamp/README.md).
- `k8s-monitoring`, `arc-systems`, `arc-runners`, `observability` (+ its
  Grafana Secrets).

### **cert-manager + external-dns secrets**

Secrets (kept out of git as SOPS-encrypted values in the shared
`../secrets.sops.yaml`).

The ArgoCD `platform` Application and the `apps`/`pdeu`/`tenants`
**ApplicationSets** are NOT managed here, they live in the separate
[`../argocd-config`](../argocd-config/README.md) unit that
runs after ArgoCD is up (otherwise the argocd provider couldn't connect during a
from-scratch apply).

Everything else (`network/gateway.yaml`, LB-IPAM pool, L2 policy, the
cert-manager/external-dns Helm `Application`s, ArgoCD's HTTPRoute) is defined in
Git (`platform/`, `apps/`) and synced by ArgoCD.

## Usage

Managed by **Terragrunt** (see [`../README.md`](../README.md)). All inputs
(incl. secret-derived ones) are resolved in `../env.hcl`; the raw secrets live
in the shared SOPS-encrypted `../secrets.sops.yaml` (decode with
`sops --decrypt ../secrets.sops.yaml`).

The kubernetes/helm providers read the cluster connection directly from the
kubeconfig the cluster unit generates (`../cluster/artifacts/kubeconfig`), so
**no `KUBECONFIG` env export is needed**. Terragrunt resolves it via env.hcl.

The ArgoCD admin password is defined once, as **plaintext** in SOPS
(`argocd_admin_password`). A one-way bcrypt of it is set
on the chart's `configs.secret.argocdServerAdminPassword`, so ArgoCD's `admin`
password is pre-determined and matches the SOPS plaintext. The argocd provider
in `../argocd-config` authenticates with that same plaintext.

One-time prerequisites:

1. Push the repo (with `platform/` + `apps/`) to the git remote ArgoCD clones.
   Public repo → no creds; private → set `github_pat`.
2. Create a Cloudflare API token (Zone.Zone read + Zone.DNS edit) and set
   `cloudflare_api_token` in `infra/secrets.sops.yaml`.
3. Confirm `192.168.0.200-219` is free on the LAN (outside the router DHCP pool).

Apply order (cluster first):

```sh
cd infra
terragrunt apply --all     # cluster -> viewer-kubeconfig, addons (this unit) -> argocd-config
# or this unit alone:  cd infra/addons && terragrunt apply
```

Once ArgoCD is up, `cd ../argocd-config && terragrunt apply` (or `--all`)
creates the `platform` Application and the ApplicationSets, and ArgoCD syncs:

- the `platform` Application applies the per-component Application manifests
  only (it is an app-of-apps); each of those applies its Helm chart
  (cert-manager, external-dns, spegel, longhorn, ...) plus the companion
  manifests in its folder, one app per component.
- `apps` ApplicationSet syncs `apps/` (ArgoCD's HTTPRoute →
  `argocd.icaninto.space`).
- Cert-manager issues the cert (DNS-01, ~1 min); external-dns creates the
  `argocd.icaninto.space` A record → `192.168.0.200`.

## Add a new app

1. Create `apps/<app>/` in the repo with your manifests (or an ArgoCD
   `Application` that points at a Helm chart, like `platform/
   external-dns/application.yaml` does).
2. Push. The `apps` ApplicationSet picks it up automatically.
3. For a public hostname: add an `HTTPRoute` (external-dns creates the DNS
   record) and a cert-manager annotation for TLS.

## Verify

```sh
kubectl -n argocd get applicationset,application
kubectl get gateway,ippool,l2announcement
dig +short argocd.icaninto.space          # -> 192.168.0.200
curl -I https://argocd.icaninto.space     # -> 200/302 with valid LE cert
```
