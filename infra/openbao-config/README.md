# openbao-config

Everything **inside** OpenBao that the `OpenBaoCluster` self-init does not own
([platform/openbao](../../platform/openbao/README.md) owns the cluster and its
bootstrap): ESO policies and Kubernetes-auth roles, tenant mounts/policies/SSO
roles, the shared `secret/` mount, and the consumer secret data. The stock
`hashicorp/vault` provider drives OpenBao (same HTTP API; the
`openbao/terraform-provider-vault` fork has no releases).

## What it does not manage (and why)

- Auth mounts and their config (`auth/oidc/*config`, `auth/kubernetes/*config`,
  the `jwt-operator` mount, the `openbao-admin` policy, `sso-admin`/`sso-user`
  roles) are **self-init** requests on the OpenBaoCluster CR. TF only writes
  resources *under* those mounts, so a fresh cluster needs no imports.
- The Terraform AppRole (`openbao-tf` role + `terraform` policy under
  `auth/approle`) is created **once manually** after self-init (see the cutover
  notes in the platform/openbao README): OIDC login as `sso-admin` → enable
  approle → create role/policy → put `role_id`/`secret_id` into SOPS
  (`openbao_approle_role_id` / `openbao_approle_secret_id`). Give it a long
  `secret_id_ttl`; when it expires, re-run `sops` with a fresh secret_id —
  no TF change.

## Inputs (`infra/env.hcl` → `locals.openbao_config`)

- `bao_address`: the Gateway-terminated public endpoint
  (`https://bao.icaninto.space`) — Atlantis reaches it over the LAN; the
  Gateway's public LE cert needs no custom CA.
- `tenants`: decoded directly from `argocd/tenants/tenants.json` — the single
  tenant source of truth (the old `TENANTS` marker is gone).
- `kv_secrets`: consumer secret values from SOPS (`secrets.openbao_kv.*`),
  one entry per kv-v2 record; `mount: secret` (shared) or a tenant mount.

## Cold bootstrap ordering

The unit can only plan/apply once ArgoCD has synced the `OpenBaoCluster`
(self-init finished) **and** the AppRole exists in SOPS. On a from-scratch
cluster the first `atlantis plan` fails with connection/auth errors — re-run
`atlantis plan` after `kubectl get openbaocluster openbao` is Ready and the
AppRole is in SOPS. Same re-plan pattern as the tenant Applications.
