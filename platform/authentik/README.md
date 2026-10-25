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
- Exposure: one issuer, https://authentik.icaninto.space, for LAN, tailnet and internet. `route.yaml`
  serves it on the `authentik-https` gateway listener with the `authentik-tls` cert-manager DNS-01
  certificate, and `redirect.yaml` sends plain HTTP there. Both routes carry the external-dns opt-out,
  so the record is made by hand; see [Exposure](#exposure) for both paths and the host-side steps.
- Network policies: `authentik-allow-gateway-ingress.yaml` (gateway → 9000),
  `authentik-allow-metrics.yaml` (Alloy → 9300) and `authentik-allow-egress.yaml` (DNS, the
  in-namespace Postgres, the SMTP relay on the submission ports, the API server for the outpost
  controller). The chart
  ships none, so these are hand-written; they select the authentik pods, not the namespace, so the
  CNPG instance keeps its own traffic.
- Observability: ServiceMonitors for server and worker; dashboard in
  `platform/observability/dashboards/authentik.yaml` (folder Authentik); rules
  `authentik-target-down` and `authentik-task-backlog` in `platform/observability/alerting/authentik.yaml`.

## Exposure

Public path: DNS-only Cloudflare record → WAN:443 → SWAG on `windrunner` → `https://192.168.0.200`
with the original Host header and SNI → gateway `authentik-https` listener → `authentik-server:9000`.
The gateway terminates TLS; the Service port in `route.yaml` is 80 and maps to container 9000.

LAN path: a router-local DNS override sends the hostname to 192.168.0.200, so LAN clients speak TLS
to the gateway directly, with no hairpin through SWAG; the nodes use the same resolver. Remote
tailnet devices take the public path; the issuer no longer rides the `lan-subnet-router` Connector.
Consumer pods that call the issuer pin the VIP with `hostAliases`, as `observability` and `headlamp`
already do for Dex, so their discovery and token requests stay on the LAN instead of following the
public record out through WAN and back.

Both routes carry `external-dns.kubernetes.io/controller: "manual-dns"` (external-dns v0.22+ ignores
the legacy `external-dns.alpha.kubernetes.io` prefix), because the annotation is per object and
external-dns unions hostnames across routes: one unannotated route still publishes this hostname.
Without the opt-out, external-dns with policy=sync publishes the cluster's RFC1918 gateway IP and
fights the hand-made record. It deletes the A/TXT records it owns on the first sync after the
opt-out lands, so the Cloudflare A record goes in once they are gone.
Put the router override in place first: LAN clients resolve through it, and until it exists the
merge leaves them without the name. cert-manager is not affected: DNS-01 issues `authentik-tls`
from a TXT challenge, not from the A record.

Host-side steps, none of them in this repo:

- The router-local DNS override above, first.
- SWAG `proxy-confs/authentik.subdomain.conf`: `proxy_pass https://192.168.0.200`, the original `Host`
  header, SNI set to the hostname, and the websocket upgrade headers. The upstream must be HTTPS: on
  plain HTTP `redirect.yaml` answers 301 to itself and the browser loops.
- A SWAG certificate covering `authentik.icaninto.space`.
- The Cloudflare A record, created by hand after external-dns has dropped its own.

Hardening for the public leg: TOTP is mandatory at login (`mfa.yaml`) and no signup or enrolment
flow is bound, so an anonymous visitor has only credentials to attack, and the recovery flow still
issues a session without TOTP (see Accounts). Add SWAG `limit_req` to the proxy conf, and
optionally 403 `/if/admin/` and `/admin/` there; the LAN path keeps full admin through the VIP.

## Seeding (one-time, after OpenBao is up)

ESO's OpenBao provider is read-only, so the values are written into OpenBao by hand first. The block
below asks for the values only you have, generates the rest, and copies the SeaweedFS key pair from
the Secret the Grafana database backs up with. Addresses and the mail relay stay in OpenBao, so this
repo carries neither.

```sh
printf 'base URL (the public https URL of this instance): '; read -r BASE_URL
printf 'akadmin email: '; read -r BOOTSTRAP_EMAIL
printf 'SMTP host: '; read -r SMTP_HOST
printf 'SMTP port [587]: '; read -r SMTP_PORT; SMTP_PORT=${SMTP_PORT:-587}
printf 'SMTP username (sending address): '; read -r SMTP_USERNAME
printf 'SMTP From address: '; read -r SMTP_FROM
printf 'SMTP password: '; read -rs SMTP_PASSWORD; printf '\n'
printf 'bbayrakt email: '; read -r BBAYRAKT_EMAIL
printf 'dhaustein email: '; read -r DHAUSTEIN_EMAIL

SECRET_KEY=$(openssl rand -base64 48)   # never change it after the first start
BOOTSTRAP_TOKEN=$(openssl rand -hex 24)
BOOTSTRAP_PASSWORD=$(openssl rand -base64 24)
S3_ACCESS_KEY=$(kubectl -n observability get secret grafana-pg-backup-s3 -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)
S3_SECRET_KEY=$(kubectl -n observability get secret grafana-pg-backup-s3 -o jsonpath='{.data.SECRET_ACCESS_KEY}' | base64 -d)

kubectl exec -n openbao openbao-0 -- sh -c "
  export BAO_ADDR=http://127.0.0.1:8200
  bao login -method=kubernetes role=openbao-admin \
    jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null
  bao kv put secret/authentik \
    secret_key=$SECRET_KEY \
    base_url=$BASE_URL \
    bootstrap_password=$BOOTSTRAP_PASSWORD \
    bootstrap_token=$BOOTSTRAP_TOKEN \
    bootstrap_email=$BOOTSTRAP_EMAIL \
    smtp_password=$SMTP_PASSWORD \
    smtp_host=$SMTP_HOST \
    smtp_port=$SMTP_PORT \
    smtp_username=$SMTP_USERNAME \
    smtp_from=$SMTP_FROM \
    s3_access_key=$S3_ACCESS_KEY \
    s3_secret_key=$S3_SECRET_KEY \
    bbayrakt_email=$BBAYRAKT_EMAIL \
    dhaustein_email=$DHAUSTEIN_EMAIL
  bao kv metadata get secret/authentik
"

# akadmin break-glass: put both of these in your password manager
printf 'akadmin (%s)\n  password: %s\n  token:    %s\n' \
  "$BOOTSTRAP_EMAIL" "$BOOTSTRAP_PASSWORD" "$BOOTSTRAP_TOKEN"
```

The `eso-authentik` role the store logs in with is written by the OpenBao chart's `postStart`, so it
only exists once this change is applied and the OpenBao StatefulSet has rolled. Seeding earlier is
harmless. `external-secrets.yaml` then templates the values into `authentik-secret` (the
`AUTHENTIK_*` keys and the two `BLUEPRINT_EMAIL_*` ones) and `authentik-pg-backup-s3`; until both
sync the pods sit in `CreateContainerConfigError`, and ESO keeps retrying.

## Base URL

`base_url` in `secret/authentik` becomes `AUTHENTIK_WEB__BASE_URL`, which sets the Base URL system
setting on first start. It is required: authentik refuses to start after the initial setup without
it, and every reset link and future OIDC issuer is built from it.

## Mail (password reset)

The relay is not named here, on purpose: host, port, username, From address and password all come
from `secret/authentik`, templated into `AUTHENTIK_EMAIL__*`. Only `AUTHENTIK_EMAIL__USE_TLS` (STARTTLS)
is in `application.yaml`, because the protocol carries no identity. Use a submission credential for
the sending address, and make sure the relay will send as that address.

Test it from the worker, which already carries the address as an env var:

```sh
kubectl -n authentik exec deploy/authentik-worker -- sh -c 'ak test_email "$BLUEPRINT_EMAIL_BBAYRAKT"'
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
- Emails are not in git: `users.yaml` reads them with `!Env BLUEPRINT_EMAIL_*`, filled from
  `secret/authentik` (`bbayrakt_email`, `dhaustein_email`) by ESO. Change an address there and roll
  the worker.
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
- **Rotating the SMTP token** is a `bao kv patch secret/authentik smtp_password=<new>`; ESO picks it
  up within the hour and reloader then rolls the pods. `kv put` would replace the whole version and
  drop the other keys, which takes the pods down.
- **Sizing** is a first estimate (2026-10-25, no history) for server, worker and the database;
  re-derive from the alerting history after two weeks.
- **Outposts:** the embedded outpost runs inside the `server` pod, so forward-auth works with no
  extra workload. Managed outposts would be Deployments created by the server, which needs the
  chart's ServiceAccount and remote-cluster ClusterRole — both off while `serviceAccount.create:`
  is `false`, so switch it on in the commit that adds the first proxy provider. Forward-auth also
  needs the apps' hostnames to route `/outpost.goauthentik.io` to authentik.

## Verify

```sh
kubectl -n authentik get externalsecret,secretstore     # SecretSynced / Valid
kubectl -n authentik get pods                          # 2/2 server, 1/1 worker, cluster Healthy
curl -v --resolve authentik.icaninto.space:443:192.168.0.200 \
  https://authentik.icaninto.space/-/health/ready/     # gateway listener, DNS bypassed
```

`--resolve` needs no DNS, so a 200 there proves the listener and certificate before either override
is in place. After the host-side steps, check both paths:

```sh
dig +short authentik.icaninto.space                      # outside: the SWAG target, LAN: 192.168.0.200
curl -I https://authentik.icaninto.space/-/health/ready/ # from outside and from the LAN
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
