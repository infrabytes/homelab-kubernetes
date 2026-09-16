# Infra (Terragrunt)

Terragrunt orchestrates the separate Terraform/OpenTofu projects (units) in this
directory. `apply --all` runs `cluster` first, then `viewer-kubeconfig` and
`addons` (independent siblings), then `argocd-config` (`grafana-cloud-config`
is order-independent and runs in parallel).

| Unit                   | Purpose                                                                  |
|------------------------|--------------------------------------------------------------------------|
| `cluster`              | Talos cluster + Cilium (kube-proxy-free, L2 LB, Gateway API CRDs)        |
| `viewer-kubeconfig`    | Mints the view-only `viewer@talos-cluster` client cert (CSR API) + kubeconfig |
| `addons`               | Installs ArgoCD, Cert Manager and ExternalDNS to bootstrap ArgoCD        |
| `grafana-cloud-config` | Grafana Cloud **watchdog** (Talos folder, PVE-maintenance dashboard + rules, cluster-heartbeat rule) via the grafana/grafana provider; no cluster dependency |
| `argocd-config`        | Configures ArgoCD resources (ApplicationSets); runs after ArgoCD exists  |

Run everything with one command from this directory:

```sh
terragrunt apply --all --provider-cache  # or: plan, validate, destroy
```

`apply --all` runs `cluster` first, then `viewer-kubeconfig` and `addons`
(independent siblings: `viewer-kubeconfig` needs the API up to mint the
viewer cert, `addons` installs ArgoCD), then `argocd-config` (once ArgoCD is
up); `destroy --all` reverses that. Keeping the ApplicationSets
in `argocd-config` (not `addons`) means a from-scratch apply never tries to use
the argocd provider before ArgoCD exists.

## Tooling

- [**Terragrunt**](https://terragrunt.com/)
- [**OpenTofu**](https://opentofu.org/) (or [Terraform](https://developer.hashicorp.com/terraform))
- [**SOPS**](https://getsops.io/) + [**age**](https://github.com/FiloSottile/age) for committing secrets

## Layout

```
infra/
  root.hcl            # shared remote_state (S3 via SeaweedFS, pbkdf2-encrypted)
  env.hcl             # ALL unit inputs + shared values (secrets decrypt, kubeconfig)
  secrets.sops.yaml   # single SOPS-encrypted secrets file (all units)
  cluster/            # unit: cluster terraform root (main.tf, ... modules/)
    terragrunt.hcl    # logic only: inputs = local.env.locals.cluster
  viewer-kubeconfig/  # unit: viewer client cert + kubeconfig (CSR API)
    terragrunt.hcl    # logic only: inputs = local.env.locals.viewer_kubeconfig
  addons/             # unit: ArgoCD install + prerequisite namespaces/secrets
    terragrunt.hcl    # logic only: inputs = local.env.locals.addons
  argocd-config/      # unit: ArgoCD ApplicationSets (argocd provider)
    terragrunt.hcl    # logic only: inputs = local.env.locals.argocd_config
  grafana-cloud-config/ # unit: Grafana Cloud watchdog (grafana/grafana provider)
    terragrunt.hcl    # logic only: inputs = local.env.locals.grafana_cloud
```

## Secrets (SOPS + AGE)

- One encrypted file for all units: `infra/secrets.sops.yaml`.
  (`.sops.yaml` at the repo root holds the recipients / creation rules.)
- The **private** AGE key is NOT in git: it lives at
  `~/.config/sops/age/keys.txt` (override with `SOPS_AGE_KEY_FILE`).

Edit/decrypt:

```sh
cd infra
sops secrets.sops.yaml           # open in $EDITOR, re-encrypts on save
sops --decrypt secrets.sops.yaml
```

Terragrunt resolves all inputs (and decrypts secrets) via `infra/env.hcl`, which
each unit's `terragrunt.hcl` reads with `read_terragrunt_config(...)`.

## Typical workflows

```sh
cd infra
terragrunt validate --all   # dry config check
terragrunt plan --all       # plan all units
terragrunt apply --all      # apply all
terragrunt destroy --all    # tear down all
```

No `KUBECONFIG` export is needed, as the `addons`/`viewer-kubeconfig`/`argocd-config`
providers resolve the cluster connection from the kubeconfig the `cluster` unit
writes (`cluster/artifacts/kubeconfig`) via `env.hcl`'s `kubeconfig_path`.

To operate on a single unit:

```sh
cd infra/cluster        && terragrunt apply
cd infra/viewer-kubeconfig && terragrunt apply
cd infra/addons         && terragrunt apply
cd infra/argocd-config  && terragrunt apply
cd infra/grafana-cloud-config && terragrunt apply
```

## View-only cluster access (viewer-kubeconfig)

A view-only user `viewer@talos-cluster` exists for read-only cluster access.

- **Grants** (`../platform/cluster-viewer/rbac.yaml`, ArgoCD-managed): everything
  the built-in `view` ClusterRole grants (`get`/`list`/`watch` on all standard
  workload resources, including chart-provided view rules, e.g. cert-manager)
  via the `rbac.authorization.k8s.io/aggregate-to-view` aggregation label. The
  aggregation is live: any future ClusterRole labeled `aggregate-to-view` (e.g.
  a chart view role) extends the viewer automatically, exactly as it does
  `view`.
- **Excluded**: Secrets (no `get`/`list`/`watch` at all; `list` returns full
  Secret objects including `data` and service-account tokens, so any Secrets
  verb would expose their contents; even secret names stay hidden), RBAC
  resources (roles, role bindings, cluster roles), Nodes, and custom resources
  without view rules (e.g. Longhorn CRs). Plain config resources are readable
  via the standard `view` rules: ConfigMaps, ServiceAccounts, pod logs and
  Events; treat them as non-secret.

The unit mints a client cert for CN `viewer@talos-cluster` via the standard
Kubernetes CSR API (signed by kube-controller-manager; the CA key never leaves
the control plane) and writes the kubeconfig to
`cluster/artifacts/viewer-kubeconfig` (gitignored, next to the admin
kubeconfig):

```sh
cd infra
terragrunt apply --all   # cluster first; the viewer unit needs the cluster unit's new outputs
kubectl --kubeconfig=cluster/artifacts/viewer-kubeconfig get pods -A
kubectl --kubeconfig=cluster/artifacts/viewer-kubeconfig get secrets -A  # Forbidden
kubectl --kubeconfig=cluster/artifacts/viewer-kubeconfig get roles -A    # Forbidden
```

A standalone `terragrunt apply --terragrunt-working-dir viewer-kubeconfig` works
too, but only after the cluster unit has been applied once with the new outputs
(its state must carry `kubernetes_ca_certificate`/`kubernetes_host`; otherwise
the unit fails with a precondition error).

The client cert is valid ~1 year (kube-controller-manager default signing
duration). Renewal is not automatic and a plain re-apply is a no-op (the CSR
resource has no expiry rotation): force a fresh CSR with
`terragrunt apply -replace=kubernetes_certificate_signing_request_v1.viewer`
(same key, new cert), or destroy and re-apply the unit to also rotate the key.
If an apply ever fails with `AlreadyExists` on the CSR, delete the stale object
first (`kubectl delete csr cluster-viewer-tls`). The cert grants nothing until
the `cluster-viewer` RBAC lands via ArgoCD after merge to main.
