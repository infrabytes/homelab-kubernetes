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
  cluster/          Talos cluster + Cilium; talos_machine/talos_cluster drive
                    in-place Talos + Kubernetes upgrades; writes
                    artifacts/kubeconfig + talosconfig
  viewer-kubeconfig/ Mints the view-only client cert + kubeconfig (CSR API, no CA key extraction)
  addons/           Installs ArgoCD, cert-manager, external-dns, OpenBao namespace + seal Secret, ARC namespaces
  grafana-cloud-config/
                    Grafana Cloud as code (grafana/grafana provider):
                    dashboards, alerting, org preferences; no cluster dependency
  argocd-config/    ArgoCD bootstrap ApplicationSet (app-of-appsets)
argocd/appsets/     committed ApplicationSets (platform, apps, pdeu, tenants), applied via the
                    Terraform bootstrap ApplicationSet
argocd/tenants/     tenant list (source of truth for the tenants ApplicationSet + the
                    openbao postStart tenant config)
charts/             in-repo Helm charts rendered by ApplicationSets (tenant-access)
platform/           ArgoCD-managed cluster-level resources (network, issuer,
                    metrics-server, kubelet-serving-cert-approver,
                    homelab-runner + cluster-viewer RBAC)
  helm-charts/      one parent ArgoCD app (app-of-apps) for the Helm chart
                    Applications (cert-manager, external-dns, Longhorn, ARC,
                    vcluster, grafana-cloud, agent-sandbox, ...)
apps/               ArgoCD-managed applications (one subdir per app)
.github/            CI workflows + scripts (pre-commit, PR preview diff)
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

Agent environment: OMP sessions run directly on the host (no sandbox). Tools and the SOPS age key are the host's; if a tool is missing from PATH, ask the user.

## Validation & pre-commit

Every change must pass `.pre-commit-config.yaml`; CI runs it on push/PR on the self-hosted `homelab-runner` (`.github/workflows/pre-commit.yaml`, pinned tool versions, tools served from the pod-local cache hydrated from the shared seed volume; see `README.md`). PR runs are diff-scoped (`--from-ref`/`--to-ref`); pushes to `main` and PRs touching hook config run the full `--all-files` sweep. Jobs run fully concurrent (per-pod emptyDir caches; only the warm workflow writes the seed, atomically — it wipes the pod-local trees before rebuilding, so the seed never accumulates old versions). Notable hooks:

- `terragrunt_fmt` + `terraform_tflint` (config: `infra/cluster/.tflint.hcl`) for `infra/`
- local `terragrunt-validate` hook (`.github/scripts/terragrunt-validate.sh`): `terragrunt validate --all` on `infra/`; skips without the SOPS age key (e.g. CI), enforcing locally where secrets decrypt
- `yamllint` (`.yamllint.yaml`; ignores `secrets.sops.yaml`, 160-char lines)
- `kubeconform` on `platform/`, `apps/` and `argocd/` YAML
- local `argocd-apps-check` hook (`.github/scripts/check-argocd-apps.py`): for every `Application` manifest under `platform/`/`apps/`, pulls its helm/OCI chart at `targetRevision` — or clones a git-sourced chart and renders its `path` (agent-sandbox) — and renders it with `helm template --include-crds` (ArgoCD's default; opt-out via `helm.skipCrds`) with its release name, namespace, values (skips if helm/PyYAML/git are missing). It also rejects duplicate mapping keys inside `helm.values` (YAML last-key-wins silently drops the earlier block — that is how the alloy-logs resources vanished) and requires every rendered container and init container to declare a CPU request, a memory request and a memory limit; chart-internal containers with no values key are exempted, with a reason, in `.github/scripts/resource-coverage-allowlist.yaml`
- local `tenant-config-check` hook (`.github/scripts/check-tenants.py`): the tenant list (`argocd/tenants/tenants.json`, members with an explicit tailnet `identity` and optional GitHub `user`) and the openbao postStart `TENANTS` marker (`<tenant>:<namespace>[:<login>[|<login>]]`) must agree on tenant/namespace/logins; members are validated (identity charset, duplicate identities, `@github` identities matching their login); also `sh -n`s the postStart script and renders `charts/tenant-access` per tenant, asserting the RoleBinding/ClusterRoleBinding/ServiceAccount/SecretStore and that both bindings' subjects equal the member identities (skips helm/PyYAML when missing)
- `detect-secrets` (baseline: `.secrets.baseline`); never add plaintext secrets. The baseline carries **no result entries** — known false positives are filtered instead: `infra/secrets.sops.yaml` and `.sops.yaml` are excluded by file (encryption is enforced by the `sops-encrypted` hook), and lines containing `passwordKey:`/`secretKeyRef`/`argocdServerAdminPassword` (chart key names, not credentials) are excluded by line. Keep it that way: drift-prone result entries get auto-rewritten by the hook on every partial commit. New false positive → extend the `--exclude-lines`/`--exclude-files` regexes in the baseline's `filters_used` (regenerate via `detect-secrets scan --exclude-files '<regex>' --exclude-lines '<regex>'`).
- `renovate-config-validator` for `renovate.json`
- `ruff-check` (astral-sh/ruff-pre-commit) for Python files
- local `sops-encrypted` hook; `*.sops.yaml` files must be encrypted

## Renovate

`renovate.json` is the single source of truth for dependency scanning. Coverage today:

- `infra/env.hcl` version pins → regex custom managers (`talos_version`, `kubernetes_version`, `cilium_chart_version`, `gateway_api_crds_version`). **Every version field in `env.hcl` MUST have a matching `customManagers` entry.**
- Terraform `helm_release` (ArgoCD in `infra/addons/main.tf`) → `terraform` manager (helm datasource). The `grafana/grafana` provider pin in `infra/grafana-cloud-config/versions.tf` is also auto-discovered by the `terraform` manager — no `customManagers` entry needed for provider pins in `.tf` files.
- ArgoCD `Application`/`ApplicationSet` manifests under `platform/`, `apps/` and `argocd/` (cert-manager, external-dns, spegel, the ARC charts, the committed `platform`/`apps`/`tenants` ApplicationSets) → `argocd` manager (helm datasource; OCI charts like cert-manager and spegel resolve via the `docker` datasource on quay.io/ghcr.io; a git-sourced chart like agent-sandbox resolves its `targetRevision` via the `git-tags` datasource). The `tenants` ApplicationSet references an in-repo chart by `path`, and in-repo charts (`charts/*`) carry no upstream version — neither needs a manager.
- Agent Sandbox's controller image tag → regex custom manager scoped to `platform/helm-charts/agent-sandbox/application.yaml` (`docker` datasource on `registry.k8s.io`). The image tag must track the chart tag, so both pins are grouped into one `platform` branch by the `matchFileNames: platform/**` package rule; never bump just one.
- Raw manifests (`metrics-server`, `kubelet-serving-cert-approver`) → `kubernetes` manager (image + API versions).
- `.github/workflows/pre-commit.yaml` + `.github/workflows/warm-tool-cache.yaml` CLI pins (terragrunt `tg_version`, tofu `tofu_version`, tflint `tflint_version`; kubeconform + pyyaml stay pre-commit-only) → regex custom managers whose `managerFilePatterns` cover both files; `.pre-commit-config.yaml` → `pre-commit` manager. The `actions/setup-python` `python-version` pin needs NO custom manager: the built-in `github-actions` manager already tracks it in every workflow file — don't add one.
- `.github/workflows/pr-preview.yaml` + `.github/workflows/warm-tool-cache.yaml`: kubectl pin (`Azure/setup-kubectl`, must match `kubernetes_version` in `env.hcl`), the helm CLI pin (`Azure/setup-helm`), and the in-vCluster Argo CD chart version (helm datasource, `argoproj.github.io/argo-helm`) → regex custom managers. The `helm/helm` CLI pin custom manager covers all three workflow files.
- Runner CLI pins (the CLIs without setup actions that the `pr-preview` workflow runs on the self-hosted runner: vcluster, argocd-diff-preview, gh, kind) → regex custom managers matching the job-env `*_VERSION` values in `.github/workflows/pr-preview.yaml` (github-releases datasource). Installed per-run by the workflow from those pins, so a bump is one env value. kubectl and helm are NOT pinned there; they come from the setup actions, which install into the pod-local `RUNNER_TOOL_CACHE` (`/opt/tool-cache/local/runner`, hydrated from the shared seed volume; see `README.md`).

**PR preview** (`.github/workflows/pr-preview.yaml`): on PRs touching `platform/`/`apps/`, a self-hosted ARC runner (`homelab-runner`) renders the base vs. target diff through a dedicated Argo CD instance that runs **inside the vCluster** (namespace `argocd-preview`, installed idempotently via `helm upgrade --install`) and posts one comment with `output/diff.md` via `argocd-diff-preview`. The diff is the entire PR gate — no preview deployment, no health checks (the former vCluster deploy/health stage with its per-app allowlist, chart mirroring, CRD supply, secret copy and cleanup job was retired; runtime issues surface post-merge via the ArgoCD sync + Grafana, rollback is a git revert). The runner SA `arc-runner` reaches the vCluster via the host Roles in `platform/homelab-runner/rbac.yaml` (`argocd-diff-preview` namespace access retired with the host diff instance; `vcluster-connect` reads the `vcluster` namespace incl. the `vc-vcluster` kubeconfig Secret). The runner PAT lives in the `arc-runner-auth` Secret (namespace `arc-runners`), synced by ESO from OpenBao (`secret/arc-runner-auth`); the addons unit only creates the namespace. `argocd-diff-preview` connects to the in-vCluster Argo CD through the vCluster kubeconfig (`vcluster connect --server https://vcluster.vcluster.svc:443 --insecure`), port-forwards to the server, and authenticates with the initial admin password from the cluster.

**Runtime validation** — none in the PR gate: chart apps and raw manifests are covered by the diff render plus pre-commit (`check-argocd-apps.py` renders every Application with its chart and values, kubeconform validates raw repo manifests). Deploy-time behavior (crashloops, bad images, webhook rejections) is observed after merge: ArgoCD syncs `main` automatically, Grafana monitors the result, rollback is a git revert. The vcluster chart (`integrations.metricsServer.enabled: true`) still serves the metrics API by proxying the host metrics-server.

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
- **ArgoCD**: `platform/` = cluster-scoped/admin resources; `apps/` = regular applications. The `platform`/`apps` ApplicationSets are committed under `argocd/appsets/` and applied by the Terraform-managed bootstrap ApplicationSet (`infra/argocd-config/`): one intermediate Application per appset dir, name `appset-{{path.basename}}`. They generate from `main` with `automated` sync (prune + selfHeal), so pushing to `main` deploys. Adding `apps/<name>/` (or a new `platform/<name>/`) is picked up automatically. Adding a new ApplicationSet = add a dir under `argocd/appsets/` (no Terraform change). Helm chart `Application`s go under `platform/helm-charts/<chart>/` so the `platform` ApplicationSet generates a single parent app that applies them (avoids one outer app per chart). Tenant access is data-driven: `argocd/tenants/tenants.json` feeds both the committed `tenants` ApplicationSet (one `charts/tenant-access` render per tenant: RBAC, ESO ServiceAccount, namespaced OpenBao store) and the openbao postStart `TENANTS` marker (mount, policies, k8s/OIDC roles); the `tenant-config-check` hook fails when the two drift.
- **Versions**: dependency pins live in `infra/env.hcl` (`talos_version`, `kubernetes_version`, `cilium_chart_version`, `gateway_api_crds_version`), `infra/*/versions.tf` (provider pins), `.github/workflows/pre-commit.yaml` + `.github/workflows/warm-tool-cache.yaml` (CLI tools), `.pre-commit-config.yaml`, ArgoCD `Application` chart `targetRevision`s, and the PR preview job env in `.github/workflows/pr-preview.yaml` (vcluster, argocd-diff-preview, gh, kind). Renovate drives bumps, so don't bump versions manually without a reason. When adding/removing a pinned dependency, update `renovate.json` per the [Renovate section](#renovate) and verify with `.github/scripts/test-renovate.py`.
- **Resource sizing**: derive requests/limits from the longest retained Grafana Cloud window — memory request = p95 rounded up to 64Mi (32Mi floor), memory limit = max(1.5x request, 1.25x observed peak), CPU request = p95 rounded up to 10m, and no CPU limits. State the measurement window in the values comment, and re-derive from the alerting history rather than hand-tuning. Exceptions are one-shot escalations with a recorded re-measure date (currently the ArgoCD application-controller 1Gi/2Gi and applicationset-controller 128Mi/256Mi, 2026-09-24).
- **Style**: Conventional Commits — `type(scope): subject`, imperative, lowercase (`conventional-commit` skill); Clean Code principles (`clean-code` skill) — comments terse, why-not-what.
- **Documentation**: keep the root `README.md` (stack overview, bootstrap/day-2 workflows) current — reflect added/removed components, bootstrap-order and exposure changes there. Detailed ops docs stay in `infra/*/README.md`.

## Rules & guardrails

- **Never** push to `main`, force-push, or rewrite history. All changes go through a branch + PR: create a dedicated git worktree under `.worktrees/` (or use the `github` tool's `pr_checkout`), commit there, push the branch, and open a PR to `main` — no direct commits to `main`, no asking first. Auth: gh CLI credential helper (`gh auth git-credential`, HTTPS, no SSH).
- **Never** run `terragrunt apply` / `destroy` / `import` against the live cluster unless the user explicitly asks. These are destructive, real-world operations.
- **Never** commit unencrypted secrets, private keys, or Terraform state. `.terraform/`, `.terragrunt-cache/`, `*.tfstate*`, and `artifacts/` are gitignored, so don't force-add them.
- **Never** edit `infra/secrets.sops.yaml` as plaintext or decrypt it into a committed file. Re-encrypt with `sops -e -i` (CI rejects unencrypted `*.sops.yaml`).
- **Never** delete or regenerate machine secrets (`talos_machine_secrets`); the local state and `artifacts/talosconfig` carry cluster identity. Losing them means the cluster can't be re-adopted.
- Don't touch `artifacts/` outputs (kubeconfig/talosconfig/viewer-kubeconfig); they are generated by the `cluster`/`viewer-kubeconfig` units. `.terragrunt-cache/` is transient, so ignore it.
- Don't modify local tooling (host-side helpers) unless asked.

## Further reading

- `README.md` (repo root): stack overview, getting started, day-2 workflows
- `infra/README.md`: Terragrunt workflow, SOPS/age, unit ordering
- `infra/cluster/README.md`: Talos provisioning, Cilium inline manifest, upgrades, pitfalls
- `infra/addons/README.md`: ArgoCD bootstrap and adding apps
- `infra/argocd-config/README.md`: ApplicationSets
- Session continuity: work may span worktrees under `.worktrees/` (gitignored) and multiple sessions — check `git status`/`git branch` and ask where a task left off before continuing.
