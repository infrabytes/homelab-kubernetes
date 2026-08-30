# addons: ArgoCD GitOps bootstrap

Installs ArgoCD and the GitOps scaffolding after the Talos cluster exists.

## What it manages

### **ArgoCD**

ClusterIP only; no LB, the Cilium Gateway fronts it  (`server.insecure` so ArgoCD
serves plain HTTP behind the Gateway's TLS). Installs the ApplicationSet CRD +
controller.

### **ArgoCD authentication (SSO-only)**

Login is exclusively via **GitHub SSO** (Dex connector, org-restricted to
`infrabytes`); no username/password login is offered. The local `admin` account
is disabled (`configs.cm."admin.enabled" = "false"`) and the only local account,
`tf-bot`, has the `apiKey` capability (token generation) but **not** `login` —
so the ArgoCD login page shows SSO only (ArgoCD hides the password form when no
enabled account has the `login` capability).

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

Note: the committed `platform`/`apps`/`pdeu` ApplicationSets also refresh
instantly on pushes to their repos (the API-server webhook matches on
`repoURL`). Only the discovery of *new* app directories (the ApplicationSet
git generator) still waits for the 3-minute poll — the ApplicationSet
controller exposes a separate webhook server that would need its own hostname
+ HTTPRoute, which is not set up.

### **cert-manager + external-dns secrets**

Secrets (kept out of git as SOPS-encrypted values in the shared
`../secrets.sops.yaml`).

The ArgoCD **ApplicationSets** (`platform`, `apps`) are NOT managed here, they
live in the separate [`../argocd-config`](../argocd-config/README.md) unit that
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
creates the ApplicationSets, and ArgoCD syncs:

- `platform` ApplicationSet syncs each `platform/` subdir (network, issuer,
  metrics-server, kubelet-serving-cert-approver) plus the single
  `platform/helm-charts/` parent app, which applies the Helm chart
  `Application`s (cert-manager, external-dns, spegel, longhorn).
- `apps` ApplicationSet syncs `apps/` (ArgoCD's HTTPRoute →
  `argocd.icaninto.space`).
- Cert-manager issues the cert (DNS-01, ~1 min); external-dns creates the
  `argocd.icaninto.space` A record → `192.168.0.200`.

## Add a new app

1. Create `apps/<app>/` in the repo with your manifests (or an ArgoCD
   `Application` that points at a Helm chart, like `platform/helm-charts/
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
