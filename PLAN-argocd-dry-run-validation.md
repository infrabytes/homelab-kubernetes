# Plan: ArgoCD-native PR validation (replace the vCluster preview)

Status: implemented 2026-09-08 (PR #109). Spike results and deviations
from the proposal are recorded inline below. Written 2026-09-08 after PR
#107's preview run demonstrated the vCluster approach's failure modes.

## 1. Goal

Validate that changed ArgoCD `Application`s under `platform/` and `apps/`
would **render and apply cleanly to the host cluster** before merge, using
ArgoCD's own machinery (dry-run sync on the **host** ArgoCD). Retire the
vCluster-based preview entirely.

## 2. Why

The vCluster preview's failures on PR #107 were all vCluster-divergence
artifacts, not predictions of host problems:

- cnpg PodMonitor sync error: `monitoring.coreos.com` CRD missing in the
  vCluster (host has it)
- cnpg namespace not found: `cnpg-system` missing in the vCluster (host has it)
- metrics-server Service invalid: port-name conflict with the vCluster's
  `metricsServer` integration (doesn't exist on the host)
- stuck operations + stuck `resources-finalizer` (empty `status.resources` +
  dead GITHUB_TOKEN between runs): ArgoCD state accumulation in the
  long-lived preview instance

"Healthy in vCluster" != "healthy on host" and vice versa. The signal is
noisy in both directions, and the maintenance surface is large (vCluster
chart app, preview ArgoCD, allowlist, CRD supply, skip list, cleanup job).

An emulation approach (helm template + `kubectl apply --dry-run=server` in a
custom script) was considered and **rejected**: it duplicates ArgoCD's
render logic and drifts from it. The validation must use ArgoCD itself.

## 3. Design

### 3.1 Validation flow (per changed app)

1. Load the app manifest from the PR branch:
   - chart apps (`platform/helm-charts/<chart>/application.yaml`): load and
     patch identity (reuse `mirrored_application` logic from
     `.github/scripts/pr-preview.py`)
   - directory apps (`platform/<app>/`, `apps/<app>/`): generate the
     Application manifest (reuse `application_manifest` logic)
2. Patch it into a **dry-run envelope** (see 3.2)
3. Create the temp app on the host ArgoCD (`argocd app create -f <manifest>`)
4. `argocd app sync <name> --dry-run`
5. Poll the operation until terminal phase (Succeeded/Failed), timeout
   ~3 min
6. Parse the result: phase, message, per-resource status
   (`syncResult.resources[].status` = Synced/SyncFailed + messages)
7. `argocd app delete <name> --cascade=false` (no finalizer -> instant)
8. Collect the per-app result

### 3.2 The dry-run envelope (CRITICAL)

- name: `dryrun-pr-<N>-<app>`, namespace: `argocd`
- label: `preview.homelab/pr: <N>` (reuse the key; the cleanup job deletes
  by it)
- `spec.source`: verbatim from the PR branch
  (`targetRevision: refs/pull/<N>/merge`)
- `spec.destination`: verbatim (the real cluster)
- `spec.project`: verbatim (`default`)
- `syncPolicy`: **strip `automated`** (never auto-sync to the host), keep
  `syncOptions` (ServerSideApply, CreateNamespace) so the dry-run matches
  the real sync
- **no `resources-finalizer`** (instant delete)
- no `argocd.argoproj.io/refresh` annotation needed (fresh app; the host
  ArgoCD uses its own stored PAT, not a job-scoped GITHUB_TOKEN, so the
  dead-token problem from the preview instance disappears)

### 3.3 Report

Post one PR comment: per-app table with ✅ applies cleanly / ❌ error
(ArgoCD's message, e.g. render error, missing CRD, missing namespace).
The dry-run result is the diff summary (per-resource status); full
before/after diff rendering is phase 2 (`argocd app diff`).

### 3.4 Workflow

Rename `.github/workflows/pr-preview.yaml` -> `pr-validate.yaml`
(workflow name "PR Validation"):

- triggers: unchanged (`pull_request` opened/synchronize/reopened/closed,
  paths `platform/**`, `apps/**`; drop the
  `.github/argocd-preview-values.yaml` + `.github/host-kubeconfig.yaml`
  path entries — those files go away)
- `validate` job (not closed): checkout `refs/pull/<N>/merge`, install
  argocd CLI (pinned; add a renovate custom manager entry per the
  runner-CLI-pin pattern), get the preview-bot token, run the script, post
  the comment. `permissions: contents: read, pull-requests: write`.
  `timeout-minutes: 15` (dry-runs are seconds per app).
- `cleanup` job (closed): delete leftover `dryrun-pr-<N>-*` apps by label
  (safety net for cancelled runs)
- concurrency group: keep per-PR

### 3.5 Credentials

Dedicated ArgoCD account `preview-bot` (apiKey), scoped to the default
project:

- `configs.cm."accounts.preview-bot" = apiKey` (addons unit, argo-cd chart
  values)
- RBAC lines in `infra/env.hcl` `addons.argocd_rbac.policy_csv`:
  `p, preview-bot, applications, create, default/*, allow`
  `p, preview-bot, applications, get, default/*, allow`
  `p, preview-bot, applications, sync, default/*, allow`
  `p, preview-bot, applications, delete, default/*, allow`
- generate the token once (`argocd account generate-token --account
  preview-bot`), store in `infra/secrets.sops.yaml` (new key, e.g.
  `argocd_preview_bot_token`), addons unit creates a Secret in
  `arc-runners` (follow the `github_runner_token` -> `arc-runner-auth`
  pattern), runner SA gets read access (extend
  `platform/homelab-runner/rbac.yaml`)

The runner reaches the host ArgoCD via the in-cluster service
(`https://argocd-server.argocd.svc:443`, `--insecure`).

## 4. Assumptions verified (spike, 2026-09-08, host ArgoCD v3.5.2)

Spike outcome, all verified with temp apps on the host ArgoCD (tf-bot
API token, `argocd app create` + `sync --dry-run` + `delete --cascade=false`):

1. **ArgoCD dry-run catches missing CRDs** ✅: a directory app whose
   manifests reference a CRD the host lacks (rollouts.argoproj.io) fails
   the dry-run with operation phase `Failed` and message
   `one or more synchronization tasks are not valid: Rollout.argoproj.io "" not found`.
2. **The host ArgoCD can fetch `refs/pull/<N>/merge`** ✅: verified with a
   git-sourced app at `refs/pull/108/merge` (open PR). Note: merged PRs
   lose their merge ref (GitHub deletes it) — irrelevant for the workflow,
   which only runs on open PRs.
3. **Dry-run sync works right after app creation** ✅: cert-manager chart
   app created, `sync --dry-run` reached `Succeeded` with per-resource
   status (`configured (dry run)` messages).
4. **Render errors surface at CREATE time** ✅ (stronger than assumed):
   ArgoCD validates the app spec by rendering the manifests, so a bad
   values key fails `argocd app create` itself with the helm template
   error (`InvalidSpecError: ... cannot unmarshal yaml document`); the app
   is never created.
5. **Missing destination namespace is NOT caught** ⚠️: the dry-run
   succeeds (every resource diffs as Missing). Supplement added: the script
   checks every namespace an app targets against the host (exists, or
   `CreateNamespace`, or a `Namespace` manifest in the app's rendered
   resources, or a `namespace.yaml` sibling applied by the helm-charts
   parent app) and fails the app otherwise.
6. **Webhook rejections are NOT caught** (ArgoCD dry-run doesn't hit the
   API server's dry-run) — documented gap, acceptable for chart apps.
7. **Temp app lifecycle is clean** ✅: `delete --cascade=false` is instant
   (no finalizer), nothing is applied to the host, no leftovers.

Also learned: the argocd CLI authenticates to the host ArgoCD with the
API token via `ARGOCD_AUTH_TOKEN` (Bearer), not `argocd login` — the
apiKey-only accounts (tf-bot, preview-bot) have no `login` capability by
design.

## 5. Implementation steps (ordered)

1. Spike (section 4) — done, results above
2. Create the `preview-bot` account + token; SOPS entry; addons unit
   Secret; runner RBAC — done (PR #109; the addons unit applies the
   account config, the token is generated and stored in SOPS, the
   `preview-bot-auth` Secret is created in `arc-runners`, the runner SA
   gets the Secret read + namespace read RBAC)
3. Write `.github/scripts/argocd-dry-run.py` (reuses `changed_files`,
   `app_for_path`, `mirrored_application`, `application_manifest` from
   `pr-preview.py`; drops the allowlist/CRD-supply/health-wait logic and
   the external-dns txtOwnerId override — the dry-run applies nothing, so
   no DNS records are ever written) — done
4. Rewrite the workflow (`pr-validate.yaml`); delete `pr-preview.yaml`,
   `pr-preview.py`, `.github/argocd-preview-values.yaml` — done
5. Test on a PR: the implementation PR itself touches `platform/` and
   `apps/`, so the workflow runs on it; the comment shows per-app results
   and temp apps are created and deleted with no leftovers — pending
6. Retire the vCluster (section 6) — the manifests are removed in PR #109;
   ArgoCD prunes the vCluster + the preview ArgoCD inside it on merge;
   verify the `vcluster` namespace is gone afterwards
7. Update docs (section 7) — done
8. `pre-commit run --all-files` + full CI pass — pending

## 6. Retire the vCluster preview

- Remove `platform/helm-charts/vcluster/` (application.yaml +
  namespace.yaml); ArgoCD prunes the vCluster + the preview ArgoCD inside
  it; the `vcluster` namespace is pruned by the helm-charts parent app
  (it applies the namespace.yaml) — done in PR #109, verify after merge
- Remove `.github/host-kubeconfig.yaml` (no other consumers) — done
- Remove runner RBAC from `platform/homelab-runner/rbac.yaml`:
  `vcluster-connect`, `arc-runner-preview-secrets`, `arc-runner-preview-crds`
  (and the already-retired `arc-runner-diff-preview`) — done; replaced with
  `arc-runner-preview-bot` (Secret read) + `arc-runner-namespace-read`
- Remove the vcluster/argocd-diff-preview/kind CLI installs from the
  workflow; remove their pins from `renovate.json` custom managers; add the
  argocd CLI pin — done
- The `argocd` manager in renovate.json stops tracking the vcluster chart
  app automatically (manifest removed) — done
- Current vCluster state (PR #107's 6 preview apps) is pruned with the
  vCluster — pending merge

## 7. Docs & config updates

- `AGENTS.md`: rewrite the PR preview section (the allowlist, CRD supply,
  vCluster, argocd-diff-preview, runner pins, cleanup job descriptions) — done
- `README.md`: update the preview workflow description — done
- `renovate.json`: remove vcluster/argocd-diff-preview/kind pins, add the
  argocd CLI pin (verify with `.github/scripts/test-renovate.py`) — done
- `infra/env.hcl`: add the preview-bot RBAC lines — done
- `infra/secrets.sops.yaml`: add the preview-bot token (edit via `sops`) — done
- `infra/addons/README.md`: document the preview-bot account — done

## 8. Risks & mitigations

- **Temp app auto-syncs to the host**: the envelope strips `automated`;
  code review; the cleanup job deletes leftovers
- **Dry-run misses webhooks/health**: documented; health remains the
  post-merge watch (ArgoCD syncs on merge, revert is a git revert)
- **Host ArgoCD load**: dry-run ops are cheap; temp apps are short-lived
- **Concurrency**: per-PR app names, no conflicts
- **The `apps/` directory apps**: no allowlist needed anymore — every
  changed app is validatable (dry-run applies nothing)

## 9. Out of scope (phase 2)

- Full before/after diff rendering in the comment (`argocd app diff`)
- Runtime health checks (image pull, startup, liveness)

## 10. Verification checklist

- [x] Spike: dry-run catches a missing CRD, a render error; a missing
      namespace is NOT caught (supplement added); temp app lifecycle is clean
- [x] Host ArgoCD fetches `refs/pull/<N>/merge` (PAT)
- [ ] Validate job posts the per-app report comment (tested on the
      implementation PR)
- [ ] No temp apps left after a run; cleanup job works on close
- [ ] vCluster + preview ArgoCD + RBAC + files removed; nothing else
      references them (verify after merge)
- [ ] `pre-commit run --all-files` passes
- [x] AGENTS.md / README.md / renovate.json updated and consistent
