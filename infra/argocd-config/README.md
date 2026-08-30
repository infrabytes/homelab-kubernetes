# argocd-config: ArgoCD bootstrap (ApplicationSets)

A separate Terragrunt unit that configures ArgoCD after it is installed
(`addons`). Runs `cluster → addons → argocd-config` via `terragrunt apply
--all`. Keeping it separate from `addons` avoids the from-scratch chicken-and-egg:
the argocd provider can only connect once the ArgoCD server exists.

## What it manages

- A single bootstrap `ApplicationSet` (`bootstrap`) via the **ArgoCD Terraform
  provider** (`argoproj-labs/argocd`, `argocd_application_set`). Its git
  directory generator matches `argocd/appsets/*` in the repo and generates one
  Application per subdir (`appset-{{path.basename}}`) that applies the
  ApplicationSet YAML committed there (app-of-appsets pattern).
- The real `platform` (cluster admin-level resources) and `apps` (regular
  applications) ApplicationSets are therefore plain GitOps manifests under
  `argocd/appsets/`, reviewable and diffable (e.g. by the Argo CD diff preview
  workflow) instead of being defined in Terraform. Adding or changing an
  ApplicationSet is a normal repo PR that needs no Terraform change.
- ArgoCD reads GitOps content only from the git repo (`gitops_repo_url` from
  `env.hcl`).

ApplicationSet dirs may carry more than ApplicationSets: `argocd/appsets/pdeu/`
(the first to do so) also contains the `pdeu` AppProject and `pdeu` Namespace,
they are plain objects applied in the same operation by the generated
`appset-pdeu` Application.

The `platform` ApplicationSet generates one app per `platform/*` folder. Helm
chart `Application`s live under `platform/helm-charts/<chart>/`; because
`platform/*` matches one level, ArgoCD generates a single parent app for
`platform/helm-charts/` that applies all chart `Application`s (app-of-apps).
This avoids one outer app per chart.

The argocd provider connects to the in-cluster server (ClusterIP) via
port-forwarding, deriving the cluster connection from the kubeconfig the
`cluster` unit writes (`../cluster/artifacts/kubeconfig` via `env.hcl`), and
authenticates with the `tf-bot` service-account API token (`argocd_tf_token`,
generated via `argocd account generate-token --account tf-bot`). While the
token is unset (fresh bootstrap, before it lands in SOPS) it falls back to the
plaintext `admin` password (`argocd_admin_password`), whose bcrypt the `addons`
unit sets on the chart (so it matches on fresh installs); once the token is
set, the addons unit disables the local admin account (SSO-only login).
ArgoCD serves plain HTTP (`server.insecure`), so the provider uses
`plain_text = true`.

## Usage

```sh
cd infra
terragrunt apply --all     # cluster -> addons -> this unit
# or this unit alone:  cd infra/argocd-config && terragrunt apply
```

Inputs come from `../env.hcl` (all unit inputs centralized there); no
`KUBECONFIG` export needed.

## Verify

```sh
kubectl -n argocd get applicationset,application
```
