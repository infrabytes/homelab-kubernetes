# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project overview

GitOps-driven homelab Kubernetes cluster. A Talos Linux cluster runs on Proxmox VE; it is provisioned with Terragrunt + OpenTofu (`infra/`) and applications are delivered by ArgoCD from this same repo (`platform/` + `apps/`).

Stack: Talos Linux - Kubernetes - Cilium (kube-proxy-free, L2 LB, Gateway API, WireGuard encryption, Hubble) - ArgoCD - cert-manager (Let's Encrypt DNS-01) - external-dns - SOPS/age - Renovate.

## Repository layout

```
infra/              Terragrunt/OpenTofu units: cluster -> viewer-kubeconfig, addons -> argocd-config
                    (grafana-cloud-config is order-independent, runs in parallel)
  env.hcl           ALL unit inputs centralized (versions, nodes, secrets)
  root.hcl          shared remote_state (S3 backend on SeaweedFS, pbkdf2-encrypted)
  secrets.sops.yaml single SOPS-encrypted secrets file (never plaintext)
  cluster/          Talos cluster + Cilium; writes artifacts/kubeconfig + talosconfig
  viewer-kubeconfig/ Mints the view-only client cert + kubeconfig (CSR API, no CA key extraction)
  addons/           Installs ArgoCD, cert-manager, external-dns, ARC namespaces
  grafana-cloud-config/
                    Grafana Cloud as code (grafana/grafana provider):
                    dashboards, alerting, org preferences; no cluster dependency
  argocd-config/    ArgoCD bootstrap ApplicationSet (app-of-appsets)
argocd/appsets/     committed ApplicationSets (platform, apps), applied via the
                    Terraform bootstrap ApplicationSet
platform/           ArgoCD-managed cluster-level resources (network, issuer,
                    metrics-server, kubelet-serving-cert-approver,
                    homelab-runner + cluster-viewer RBAC,
                    vpa Service/ServiceMonitor + VPA objects)
  helm-charts/      one parent ArgoCD app (app-of-apps) for the Helm chart
                    Applications (cert-manager, external-dns, Longhorn, ARC,
                    vcluster, grafana-cloud, vpa, ...)
apps/               ArgoCD-managed applications (one subdir per app)
.github/            CI workflows + scripts (pre-commit, PR preview with vCluster deploy)
.pre-commit-config.yaml  the single lint/format gate
renovate.json       dependency automation
```

## Commands

```sh
pre-commit run --all-files         # run every lint/format gate locally
cd infra && terragrunt validate --all
cd infra && terragrunt plan --all
cd infra && terragrunt apply --all   # CAUTION: mutates the live cluster
cd infra && terragrunt destroy --all # CAUTION: destroys everything
sops infra/secrets.sops.yaml         # edit secrets (re-encrypts on save)
.github/scripts/test-renovate.py     # local Renovate dry-run; verify dep extraction/updates (no branches/PRs)
```

Sandbox note: agent sessions run in a Docker sandbox, repo mounted read-write at `/workspace`, no host access; `terragrunt`/`tofu`/`tflint`/`kubeconform` live in `/root/bin` — `export PATH=$PATH:/root/bin`; `sops` and the age key are host-only.

## Validation & pre-commit

Every change must pass `.pre-commit-config.yaml`; CI runs it on push/PR on the self-hosted `homelab-runner` (`.github/workflows/pre-commit.yaml`, pinned tool versions, tools served from the pod-local cache hydrated from the shared seed volume; see `README.md`). Jobs run fully concurrent (per-pod emptyDir caches; only the warm workflow writes the seed, atomically). Notable hooks:

- `terragrunt_fmt` + `terraform_tflint` (config: `infra/cluster/.tflint.hcl`) for `infra/`
- local `terragrunt-validate` hook (`.github/scripts/terragrunt-validate.sh`): `terragrunt validate --all` on `infra/`; skips without the SOPS age key (e.g. CI), enforcing locally where secrets decrypt
- `yamllint` (`.yamllint.yaml`; ignores `secrets.sops.yaml`, 160-char lines)
- `kubeconform` on `platform/`, `apps/` and `argocd/` YAML
- local `argocd-apps-check` hook (`.github/scripts/check-argocd-apps.py`): for every `Application` manifest under `platform/`/`apps/`, pulls its helm/OCI chart at `targetRevision` (or shallow-clones the repo for git-sourced charts, e.g. the vpa chart app) and renders it with `helm template --include-crds` (ArgoCD's default; opt-out via `helm.skipCrds`) with its release name, namespace, values (skips if helm/PyYAML are missing)
- `detect-secrets` (baseline: `.secrets.baseline`); never add plaintext secrets. The baseline carries **no result entries** — known false positives are filtered instead: `infra/secrets.sops.yaml` and `.sops.yaml` are excluded by file (encryption is enforced by the `sops-encrypted` hook), and lines containing `passwordKey:`/`secretKeyRef`/`argocdServerAdminPassword` (chart key names, not credentials) are excluded by line. Keep it that way: drift-prone result entries get auto-rewritten by the hook on every partial commit. New false positive → extend the `--exclude-lines`/`--exclude-files` regexes in the baseline's `filters_used` (regenerate via `detect-secrets scan --exclude-files '<regex>' --exclude-lines '<regex>'`).
- `renovate-config-validator` for `renovate.json`
- `ruff-check` (astral-sh/ruff-pre-commit) for Python files
- local `sops-encrypted` hook; `*.sops.yaml` files must be encrypted

## Renovate

`renovate.json` is the single source of truth for dependency scanning. Coverage today:

- `infra/env.hcl` version pins → regex custom managers (`talos_version`, `kubernetes_version`, `cilium_chart_version`, `gateway_api_crds_version`). **Every version field in `env.hcl` MUST have a matching `customManagers` entry.**
- Terraform `helm_release` (ArgoCD in `infra/addons/main.tf`) → `terraform` manager (helm datasource). The `grafana/grafana` provider pin in `infra/grafana-cloud-config/versions.tf` is also auto-discovered by the `terraform` manager — no `customManagers` entry needed for provider pins in `.tf` files.
- ArgoCD `Application`/`ApplicationSet` manifests under `platform/`, `apps/` and `argocd/` (cert-manager, external-dns, spegel, the ARC charts, the VPA chart app in `platform/helm-charts/vpa/`, the committed `platform`/`apps` ApplicationSets) → `argocd` manager (helm datasource; OCI charts like cert-manager and spegel resolve via the `docker` datasource on quay.io/ghcr.io; the VPA chart's git `targetRevision` resolves via `git-tags` on kubernetes/autoscaler).
- Raw manifests (`metrics-server`, `kubelet-serving-cert-approver`) → `kubernetes` manager (image + API versions).
- `.github/workflows/pre-commit.yaml` + `.github/workflows/warm-tool-cache.yaml` CLI pins (terragrunt `tg_version`, tofu `tofu_version`, tflint `tflint_version`; kubeconform + pyyaml stay pre-commit-only) → regex custom managers whose `managerFilePatterns` cover both files; `.pre-commit-config.yaml` → `pre-commit` manager. The `actions/setup-python` `python-version` pin needs NO custom manager: the built-in `github-actions` manager already tracks it in every workflow file — don't add one.
- `.github/workflows/pr-preview.yaml` + `.github/workflows/warm-tool-cache.yaml`: kubectl pin (`Azure/setup-kubectl`, must match `kubernetes_version` in `env.hcl`), the helm CLI pin (`Azure/setup-helm`), and the in-vCluster Argo CD chart version (helm datasource, `argoproj.github.io/argo-helm`) → regex custom managers. The `helm/helm` CLI pin custom manager covers all three workflow files.
- Runner CLI pins (the CLIs without setup actions that the `pr-preview` workflow runs on the self-hosted runner: vcluster, argocd-diff-preview, gh, kind) → regex custom managers matching the job-env `*_VERSION` values in `.github/workflows/pr-preview.yaml` (github-releases datasource). Installed per-run by the workflow from those pins, so a bump is one env value. kubectl and helm are NOT pinned there; they come from the setup actions, which install into the pod-local `RUNNER_TOOL_CACHE` (`/opt/tool-cache/local/runner`, hydrated from the shared seed volume; see `README.md`).

**PR preview** (`.github/workflows/pr-preview.yaml`): on PRs touching `platform/`/`apps/`, a self-hosted ARC runner (`homelab-runner`) 1) renders the base vs. target diff through a dedicated Argo CD instance that runs **inside the vCluster** (namespace `argocd-preview`, installed idempotently via `helm upgrade --install`), 2) deploys changed, allowlisted apps as `preview-pr-<N>-<app>` Applications (targetRevision `refs/pull/<N>/merge`, automated sync, resources finalizer), and 3) posts one comment with `output/diff.md` plus the per-app health report (`output/preview-report.md` from `.github/scripts/pr-preview.py`). The allowlist (what is testable in a vCluster: no host infra, no storage, no credentials) lives in the script; everything else is skipped with a reason. On PR close a cleanup job deletes the `preview-pr-<N>-*` Applications (prune removes the workloads). The runner SA `arc-runner` reaches the vCluster via the host Roles in `platform/homelab-runner/rbac.yaml` (`argocd-diff-preview` namespace access retired with the host diff instance; `vcluster-connect` reads the `vcluster` namespace incl. the `vc-vcluster` kubeconfig Secret; `arc-runner-preview-secrets` reads the Cloudflare token; `arc-runner-preview-crds` reads CRDs cluster-wide). The runner PAT lives in the `arc-runner-auth` Secret (namespace `arc-runners`), fed from the SOPS `github_runner_token` via the addons unit. `argocd-diff-preview` connects to the in-vCluster Argo CD through the vCluster kubeconfig (`vcluster connect --server https://vcluster.vcluster.svc:443 --insecure`), port-forwards to the server, and authenticates with the initial admin password from the cluster.

**Preview upgrade testing** — chart/mirror apps: Helm-chart `Application`s under `platform/helm-charts/` (cert-manager, external-dns, vpa) and the raw `platform/vpa` manifests are on the preview allowlist. Chart apps are deployed by **mirroring** the committed Application manifest (`pr-preview.py` loads `application.yaml` from the PR branch and patches identity + the standard preview sync envelope; `spec.source`/`spec.destination` stay verbatim, so the chart, `targetRevision` and values under test are exactly what merges to `main`; the report row states `chart <name>@<targetRevision>`). The only override: the preview external-dns gets `helm.parameters: [{name: txtOwnerId, value: "preview"}]` (ArgoCD parameters win over values, so the preview instance never fights the host instance — owner `homelab` — over TXT records). It runs with the **real Cloudflare token** and can write DNS records for preview-local resources (accepted trade-off; records self-clean on prune, an orphan TXT record is possible on app death). Host Gateway API objects are not visible in the vCluster (`sync.fromHost.customResources` on the vcluster chart 0.36.1 is a **vCluster.Pro feature**, omitted by design — see below), so the preview external-dns idles by default. The workflow copies the `cloudflare-api-token` Secret data-only host → vCluster (idempotent; persists after PR close — same trust domain as host pods, intentionally no cleanup). **CRD supply**: cert-manager (`installCRDs: true`) and VPA (chart `crds/` dir) install their CRDs inside the vCluster themselves; the gateway API CRDs the cert-manager (`config.gatewayAPI.enabled`) and external-dns (`gateway-httproute` source) previews require, plus the VPA/ServiceMonitor CRDs for `platform/vpa`, are copied by `pr-preview.py` from the host cluster into the vCluster before the app is created (read-only `get` on the host; stripped definition applied in-vCluster; idempotent). The vcluster chart (values: `telemetry.enabled: false`, `integrations.metricsServer.enabled: true` so the preview VPA recommender has a metrics API) is itself `platform/helm-charts/vcluster` and therefore always skipped in preview; its changes deploy via the host ArgoCD and restart the vCluster control plane once. **Spike outcome** (in-vCluster CRD creates; verified by the first post-merge validation PR bumping cert-manager — check `kubectl get crd -l vcluster.loft.sh/managed-by` on the host stays empty): pending. Known noise: concurrent PRs touching the same chart app deploy into the same preview namespace and can fight over ArgoCD ownership (acceptable for a homelab; per-PR vClusters are the documented future fix).

When adding or removing a component:

- New version pin in `env.hcl` (or any new `*.hcl`/workflow file) → add the corresponding custom manager; on removal, delete the entry.
- New manifests under `platform/`, `apps/` or `argocd/` → auto-discovered by the `argocd`/`kubernetes` managers, no config change needed (just ship the manifest).
- Removing an Application/manifest → no config change needed; remove the manifest only.

Verify renovate changes with `.github/scripts/test-renovate.py` before pushing (pinned renovate version; needs `gh` auth or `GITHUB_TOKEN`).

- Custom-manager file matching is `managerFilePatterns` in Renovate 44.x (was `fileMatch` before v44). Always validate with the pinned version (`pre-commit run renovate-config-validator --all-files`); a stale `npx` cache runs an old renovate and reports false errors.
- Local dry-runs need Node matching renovate's engine (44.x: `^24.11.0`; use the pre-commit `node_env-lts` node if the system node is too new) and a token via `RENOVATE_HOST_RULES` (`platform=local` does not auto-inject `RENOVATE_TOKEN`).

## Conventions

- **Terragrunt**: put unit inputs (and derived values) in `infra/env.hcl`, one `locals.cluster` / `locals.viewer_kubeconfig` / `locals.addons` / `locals.grafana_cloud` / `locals.argocd_config` map. A unit's `terragrunt.hcl` only wires `inputs = local.env.locals.<unit>` and carries no values. `apply --all` runs `cluster` first, then `viewer-kubeconfig` and `addons` (independent siblings), then `argocd-config`; `destroy --all` reverses it. Providers resolve the cluster connection from `cluster/artifacts/kubeconfig` via `env.hcl`, so no `KUBECONFIG` export is needed. The `grafana-cloud-config` unit is the exception: Grafana Cloud API via the grafana/grafana provider (stack service-account token from SOPS), no `dependencies {}` block, runs in parallel.
- **Secrets**: one SOPS-encrypted file, `infra/secrets.sops.yaml` (recipients in `.sops.yaml`). Edit only via `sops`. The age key is NOT in the repo.
- **Secrets in sandboxed sessions**: the age key is root-only and unreachable, so you cannot decrypt or edit `infra/secrets.sops.yaml`. When a new secret is discovered mid-session, do NOT edit the encrypted file — ask the user to add it from the host with
  `sops set infra/secrets.sops.yaml '["key"]' '"value"'` (or a host-side sandbox helper), then re-run `sudo tg-run` — the change is live via the shared mount.
- **ArgoCD**: `platform/` = cluster-scoped/admin resources; `apps/` = regular applications. The `platform`/`apps` ApplicationSets are committed under `argocd/appsets/` and applied by the Terraform-managed bootstrap ApplicationSet (`infra/argocd-config/`): one intermediate Application per appset dir, name `appset-{{path.basename}}`. They generate from `main` with `automated` sync (prune + selfHeal), so pushing to `main` deploys. Adding `apps/<name>/` (or a new `platform/<name>/`) is picked up automatically. Adding a new ApplicationSet = add a dir under `argocd/appsets/` (no Terraform change). Helm chart `Application`s go under `platform/helm-charts/<chart>/` so the `platform` ApplicationSet generates a single parent app that applies them (avoids one outer app per chart).
- **Versions**: dependency pins live in `infra/env.hcl` (`talos_version`, `kubernetes_version`, `cilium_chart_version`, `gateway_api_crds_version`), `infra/*/versions.tf` (provider pins), `.github/workflows/pre-commit.yaml` + `.github/workflows/warm-tool-cache.yaml` (CLI tools), `.pre-commit-config.yaml`, ArgoCD `Application` chart `targetRevision`s, and the PR preview job env in `.github/workflows/pr-preview.yaml` (vcluster, argocd-diff-preview, gh, kind). Renovate drives bumps, so don't bump versions manually without a reason. When adding/removing a pinned dependency, update `renovate.json` per the [Renovate section](#renovate) and verify with `.github/scripts/test-renovate.py`.
- **VPA recommendations**: the VPA recommender (recommendation-only: updater and admission controller disabled, no pod is ever mutated) is installed from the official `vertical-pod-autoscaler` chart via `platform/helm-charts/vpa/application.yaml` (git source, `targetRevision` tracked by the `argocd` manager; the chart's `crds/` directory is applied by ArgoCD via `helm template --include-crds`). Every new workload (Deployment/StatefulSet/DaemonSet) under `platform/` or `apps/` gets a `VerticalPodAutoscaler` object (`updateMode: Off`) in the matching file under `platform/vpa/` (one file per namespace group; see `platform/vpa/README.md` for how to read `status.recommendation`). Infra-deployed workloads from the cluster unit (cilium/cilium-envoy/cilium-operator, coredns, hubble-relay in kube-system) are covered too; VPA objects are plain CRs and recommend regardless of who deploys the target. When applying their recommendations, configure the cluster unit (env.hcl / infra/cluster), not `platform/vpa/`. Set `resources.requests`/`limits` from accumulated VPA recommendations (`target`/`upperBound`), not guesses; keep the objects as a continuous drift monitor. Skip runtime-generated workloads (ARC runner StatefulSets, Longhorn engine-image DaemonSets/InstanceManager pods/csi sidecars); their resources are set via chart values instead. VPA does not cover storage; size PVCs from the Grafana Cloud queries in `platform/vpa/README.md`. On a Renovate chart-tag bump, reconcile `recommender.image.tag` in the same change (the chart's `appVersion` lags its tags).
- **Style**: Conventional Commits — `type(scope): subject`, imperative, lowercase (`conventional-commit` skill); Clean Code principles (`clean-code` skill) — comments terse, why-not-what.
- **Documentation**: keep the root `README.md` (stack overview, bootstrap/day-2 workflows) current — reflect added/removed components, bootstrap-order and exposure changes there. Detailed ops docs stay in `infra/*/README.md`.

## Rules & guardrails

- **Never** push to `main`, force-push, or rewrite history. In a git worktree (`.worktrees/`), commit, push branches, and open PRs without asking. Outside a worktree, commit/push/PR only when the user explicitly asks — default: make the change and stop for diff review. Auth: `GIT_ASKPASS` + sandbox `GITHUB_TOKEN` (HTTPS, no SSH).
- **Never** run `terragrunt apply` / `destroy` / `import` against the live cluster unless the user explicitly asks. These are destructive, real-world operations.
- **Never** commit unencrypted secrets, private keys, or Terraform state. `.terraform/`, `.terragrunt-cache/`, `*.tfstate*`, and `artifacts/` are gitignored, so don't force-add them.
- **Never** edit `infra/secrets.sops.yaml` as plaintext or decrypt it into a committed file. Re-encrypt with `sops -e -i` (CI rejects unencrypted `*.sops.yaml`).
- **Never** delete or regenerate machine secrets (`talos_machine_secrets`); the local state and `artifacts/talosconfig` carry cluster identity. Losing them means the cluster can't be re-adopted.
- Don't touch `artifacts/` outputs (kubeconfig/talosconfig/viewer-kubeconfig); they are generated by the `cluster`/`viewer-kubeconfig` units. `.terragrunt-cache/` is transient, so ignore it.
- Don't modify local tooling (`.opencode/`, host-side helpers) unless asked.

## Further reading

- `README.md` (repo root): stack overview, getting started, day-2 workflows
- `infra/README.md`: Terragrunt workflow, SOPS/age, unit ordering
- `infra/cluster/README.md`: Talos provisioning, Cilium inline manifest, upgrades, pitfalls
- `infra/addons/README.md`: ArgoCD bootstrap and adding apps
- `infra/argocd-config/README.md`: ApplicationSets
- Session continuity: work may span worktrees under `.worktrees/` (gitignored) and multiple sessions — check `git status`/`git branch` and ask where a task left off before continuing.
