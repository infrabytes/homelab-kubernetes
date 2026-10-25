# authentik: identity provider for the cluster

Local-account IdP (no external OAuth source): users, groups, TOTP enforcement and the
password-reset flow are Blueprints committed in this folder. It is the target for every SSO
consumer the cluster moves off Dex onto — see the migration table at the end.

- Chart app: `application.yaml` (`oci://ghcr.io/goauthentik/helm-charts/authentik`, version pinned
  there, Renovate-tracked through the `argocd` manager). 2 `server` replicas behind the gateway plus
  1 `worker`; no Redis (authentik dropped it in 2025.10).
- Database: the `authentik-pg` CloudNativePG cluster in `postgres.yaml` (Longhorn, daily barman
  backup to the SeaweedFS bucket). The chart's bundled Postgres stays disabled.
- Secrets: OpenBao path `secret/authentik`, synced by ESO through the namespaced store
  `openbao-authentik` (`service-account.yaml`, `secret-store.yaml`, `external-secrets.yaml`).
  The OpenBao policy/role `eso-authentik` is written by the OpenBao chart's `postStart`.
  The Postgres app-user password is not in OpenBao — CNPG generates it in `authentik-pg-app`.
- Exposure: `route.yaml` + `redirect.yaml` on the LAN at https://authentik.icaninto.space
  (`authentik-https` gateway listener, cert-manager DNS-01 cert, external-dns record, DNS-only).
  Tailnet devices reach the same URL through the `lan-subnet-router` Connector, so there is exactly
  one issuer for LAN and remote clients.
- Network policies: `authentik-allow-gateway-ingress.yaml` (gateway → 9000),
  `authentik-allow-metrics.yaml` (Alloy → 9300) and `authentik-allow-egress.yaml` (DNS, the
  in-namespace Postgres, Proton SMTP on 587, the API server for the outpost controller). The chart
  ships none, so these are hand-written; they select the authentik pods, not the namespace, so the
  CNPG instance keeps its own traffic.
- Observability: ServiceMonitors for server and worker; dashboard in
  `platform/observability/dashboards/authentik.yaml` (folder Authentik); rules
  `authentik-target-down` and `authentik-task-backlog` in `platform/observability/alerting/authentik.yaml`.

## Seeding (one-time, after OpenBao is up)

ESO's OpenBao provider is read-only, so the values are written into OpenBao by hand first.
Generate them with `openssl rand -base64 48` (or `pwgen -s 50 1`):

```sh
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200
  bao login -method=kubernetes role=openbao-admin jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
  bao kv put secret/authentik \
    secret_key=<50+ chars, never change it after the first start> \
    bootstrap_password=<akadmin break-glass password> \
    bootstrap_token=<akadmin API token> \
    bootstrap_email=bbayrakt@infrabytes.dev \
    smtp_password=<Proton SMTP token> \
    s3_access_key=<SeaweedFS key> \
    s3_secret_key=<SeaweedFS secret>
'
```

`external-secrets.yaml` templates those into `authentik-secret` (`AUTHENTIK_*`) and
`authentik-pg-backup-s3`. Until both sync the pods sit in `CreateContainerConfigError`; ESO retries,
so seeding after the first reconcile is fine.

## Mail (Proton Mail SMTP submission)

`global.env` in `application.yaml` points authentik at `smtp.protonmail.ch:587` (STARTTLS) with
`authentik@infrabytes.dev`; the password is the SMTP token in OpenBao. Generate a token in Proton
Mail under Settings → All settings → IMAP/SMTP → SMTP tokens for that custom-domain address (the
address must be active for the domain). Test it from the worker:

```sh
kubectl -n authentik exec deploy/authentik-worker -- ak test_email bbayrakt@infrabytes.dev
```

## Blueprints (config-as-code)

`blueprints/blueprints.yaml` holds three files, mounted into the worker by the chart:

- `users.yaml` — the two local accounts. Usernames match the GitHub logins the cluster's RBAC
  already names (`bbayrakt`, `dhaustein`), so ArgoCD rules, Headlamp identities and OpenBao claims
  keep matching after cutover. `bbayrakt` is in the built-in `authentik Admins` group.
- `mfa.yaml` — retargets the shipped `default-authentication-mfa-validation` stage to
  `device_classes: [totp]` with `not_configured_action: configure`, so every account without a TOTP
  device is walked into the shipped setup flow at login.
- `recovery.yaml` — the recovery flow (identification → email token → set password → login) and the
  `recovery_flow` link on the login screen's identification stage, which is what makes
  "Forgot password?" appear.

Blueprints are re-read by the worker (mounted volume) and re-applied on change; deleting a file here
does not delete the objects it created. The files own the fields they list — `name`, `email` and
`groups` on a user are reset on every apply, so add group membership here, not in the admin UI.
Reloader rolls the worker when the ConfigMap changes, so a committed edit applies on the next sync
without a manual restart.

## Accounts

- `akadmin` stays as the break-glass superuser (password and API token from
  `AUTHENTIK_BOOTSTRAP_*`; those are read only on first start against an empty database). Change its
  password on first login — the bootstrap password is long-lived otherwise.
- Everyone else sets a password through the recovery flow, then enrols TOTP at the next login.
- User emails default to `<login>@infrabytes.dev` in `users.yaml`; correct them there if they differ.
- **A password reset signs the user in without TOTP.** The recovery flow ends in a login, so mailbox
  access alone is enough to get a session; TOTP is checked on the next normal login. That is
  deliberate: it is also the way back in when the MFA stage edit breaks the login flow (which would
  lock out `akadmin` too). Closing it means adding an authenticator-validate stage to the recovery
  flow and losing that fallback.

## Operations

- **The recovery form asks for the password once.** A repeat field would need a validation policy to
  mean anything (`user_write` only reads `password`), and a broken policy here would block the only
  way back into a locked-out flow.
- **`secret_key` is permanent.** Changing it invalidates every session and encrypted value;
  rotate it only with the plan to re-run the recovery flow for everyone.
- **Rotating the SMTP token** is a `bao kv put secret/authentik smtp_password=<new>`; ESO picks it
  up within the hour and reloader then rolls the pods.
- **Sizing** is a first estimate (2026-10-25, no history) for server, worker and the database;
  re-derive from the alerting history after two weeks.
- **Outposts:** the embedded outpost runs inside the `server` pod, so forward-auth works with no
  extra workload. Managed outposts would be Deployments created by the server — for that the
  chart's ServiceAccount and cluster RBAC (kept enabled) must stay. Forward-auth also needs the
  apps' hostnames to route `/outpost.goauthentik.io` to authentik.

## Verify

```sh
kubectl -n authentik get externalsecret,secretstore     # SecretSynced / Valid
kubectl -n authentik get pods                          # 2/2 server, 1/1 worker, cluster Healthy
curl -sS https://authentik.icaninto.space/-/health/ready/
```

Then sign in at https://authentik.icaninto.space as `akadmin`, check Admin → Blueprints shows the
three files applied, reset `bbayrakt`'s password through "Forgot password?", and confirm the login
demands a TOTP device.

## Migration target (later PRs)

| Consumer | authentik mechanism |
|---|---|
| ArgoCD | OIDC (`oidc.config`) replacing the embedded Dex, groups claim for RBAC |
| Grafana | `auth.generic_oauth` → authentik; tailnet path keeps `auth.proxy` |
| Headlamp | OIDC + Talos `KubeAuthenticationConfig` issuer swap, `rbac.yaml` identities |
| OpenBao | `auth/oidc` config in the chart `postStart` + the tenant `sso-<tenant>` roles |
| Longhorn, Hubble UI, SeaweedFS, Atlantis, vmui | proxy provider + `forward_auth` on the embedded outpost |
| Dex, dex-tailnet, ArgoCD embedded Dex | deleted once every row above is migrated |
