# OpenBao operator 0.7 API-group migration (0.6.3 → 0.7.0)

Operator 0.7.0 serves `OpenBaoCluster`/`OpenBaoTenant`/`OpenBaoRestore` as
`kubebao.org/v1alpha1` and no longer reconciles `openbao.org` resources. An
in-place chart upgrade leaves the OpenBao server running without an operator.
The move is a live-cluster migration driven by the 0.7.0 `api-migration`
binary; this file is the runbook for the Argo CD route, which is how the
operator chart is installed here ([platform/openbao-operator](../openbao-operator/)).

Source: <https://docs.kubebao.org/docs/operate/api-group-migration/argocd/>
(0.7.0 guide; keep this file and the guide in sync when touching the
migration again, 0.8.0 removes the tool).

State of this migration (2026-11-23): **not yet run against the live
cluster**. Rehearsed end-to-end in kind (2026-11-24): operator 0.6.3 → 0.7.0
with the `openbaocluster.yaml` CR (Cilium/Gateway/Longhorn specifics
adapted to kind), `plan` → `migrate` → `commit` → `convert` → old-CRD
deletion all green, and the converted CR validates against the vendored
`.kubeconform/kubebao.org/` schemas. Before the live run: re-check the guide
for changed commands, then update this file.

Gotchas from the kind rehearsal that apply to the live run:

- `helm upgrade` on an existing release does **not** install the chart's
  CRDs (crds/ dir). Apply `kubectl apply --server-side -f <chart>/crds/`
  explicitly at the `stopped` checkpoint, regardless of the install route.
- The migration tool sets `.spec.replicas` on the operator Deployment as
  field manager `kubebao-api-migration`. A later checkpoint apply (helm,
  Argo CD sync or kubectl) conflicts with it; apply the checkpoint's rendered
  Deployment with `kubectl apply --server-side --force-conflicts` and let
  the destination manager take ownership back.
- The `stopped`/`held`/`normal` checkpoint values files are
  `migration-state/checkpoints/<state>-values.yaml` (e.g. `held` =
  `controller.apiMigrationHold: true, replicas: 1`).

## What moves where

| Piece | Before | After |
| --- | --- | --- |
| Chart pin, `platform/openbao-operator/application.yaml` | 0.6.3 | 0.7.0 (Renovate PR) |
| CR apiVersion, `platform/openbao/openbaocluster.yaml` | `openbao.org/v1alpha1` | `kubebao.org/v1alpha1` (`api-migration convert --write`) |
| kubeconform schemas | `.kubeconform/openbao.org/` | `.kubeconform/kubebao.org/` (vendored in this branch) |
| OpenBao server | 2.7.2 | stays 2.7.2 through the migration, rolls to 2.7.3 after (the CR `spec.version` bump in the Renovate PR) |

Labels/annotations/finalizers keep their `openbao.org/` prefixes after
conversion. Terraform (`infra/openbao-config`) talks to OpenBao over HTTP,
not the CRD API: untouched.

## Preflight

- Operator is 0.6.3 (`kubectl -n openbao-operator-system get deploy -o
  jsonpath='{.items[*].spec.template.spec.containers[0].image}'`), one
  controller replica (chart default), admission policies on (defaults).
- No in-flight operation: no `openbao.org/trigger-backup` annotation, no
  pending `OpenBaoRestore`, CR is `Available` at its current generation:
  `kubectl -n openbao get openbaoclusters.openbao.org openbao -o yaml`.
- Argo CD shows `openbao` and `openbao-operator` Synced/Healthy, and nothing
  else touching `platform/openbao*` is mid-flight (check Renovate PRs).
- Optional but recommended rollback insurance: log in as `sso-admin` and mint
  a token for `plan`'s Raft snapshot
  (`bao login -method=oidc && bao token create -policy=openbao-admin
  -ttl=2h`), save to a `0600` file. Without it the migration still works,
  just without the snapshot.
- Admin kubeconfig + `kubectl` on the migration host; verify context:

  ```sh
  export KUBECONFIG=infra/cluster/artifacts/kubeconfig
  kubectl config current-context
  ```

## Prepare Git before touching the cluster

Work in a branch off `main` (e.g. `feat/openbao-operator-0.7-migration`).
Prepared commits, **none merged before commit**:

1. Runbook + `.kubeconform/kubebao.org/` schemas (already on the branch).
2. Renovate PR #703 (chart 0.6.3→0.7.0, OpenBao 2.7.2→2.7.3, pi 1.5.2→1.6.0)
   stays open; merge only after `commit`. The safe parts (pi, 2.7.3) could
   merge earlier, but keep the whole PR for after to avoid it recreating
   mid-migration.
3. The CR conversion (`api-migration convert --write platform/openbao/openbaocluster.yaml`)
   is done **after** `commit` and pushed as its own commit.

## Suspend GitOps sync

Outermost inward. The `bootstrap` ApplicationSet template re-renders
`spec.syncPolicy` onto `appset-platform` on every reconcile, so first tell it
to stop owning that field (Terraform-owned; revert after the migration):

```sh
kubectl -n argocd patch applicationset bootstrap --type=merge \
  -p '{"spec":{"ignoreApplicationDifferences":[{"jqExpressions":["/spec/syncPolicy"]}]}}'
argocd app set appset-platform --sync-policy none || argocd app set platform --sync-policy none
argocd app set openbao --sync-policy none
argocd app set openbao-operator --sync-policy none
```

Confirm no controller re-enables automation while the migration runs
(`argocd app list` every time you come back to the shell).

## Run the migration

Same binary and state directory for `plan`, `migrate`, `commit`, `rollback`
and every retry. `--timeout` is not saved in the plan, so export it once and
keep it in every shell.

```sh
gh release download 0.7.0 --repo kubebao/openbao-operator --pattern api-migration-linux-amd64
gh attestation verify api-migration-linux-amd64 --repo kubebao/openbao-operator \
  --signer-workflow kubebao/openbao-operator/.github/workflows/release.yml \
  --source-ref refs/tags/0.7.0
chmod +x api-migration-linux-amd64 && mv api-migration-linux-amd64 api-migration
./api-migration version   # must print 0.7.0

cat > config.json <<EOF
{
  "kubeconfig": "$KUBECONFIG",
  "operatorNamespace": "openbao-operator-system",
  "sourceVersion": "0.6.3"
}
EOF
export MIGRATION_TIMEOUT=90m
./api-migration plan --config config.json --state migration-state
```

Review the plan output (context, releases, affected objects, snapshot
coverage). Then:

```sh
./api-migration migrate --state migration-state --timeout "$MIGRATION_TIMEOUT"
```

Exit status 4 = a checkpoint waits. Read the printed
`migration-state/checkpoints/<state>.md` and apply **only the named operator
resources, never pruning**:

- `stopped` (during `migrate`): push a staged commit that bumps the operator
  chart to 0.7.0 with `controller.replicas: 0` layered over the checkpoint
  values. The chart's CRDs don't come through a `--resource`-filtered sync,
  so apply them first:

  ```sh
  helm pull oci://ghcr.io/kubebao/charts/openbao-operator --version 0.7.0
  tar -xzf openbao-operator-0.7.0.tgz
  kubectl apply --server-side -f openbao-operator/crds/
  argocd app sync openbao-operator --resource <selectors from the checkpoint file>
  ```

  Do NOT sync the `openbao` Application here: Git still describes the source
  API group and a full sync would recreate retired resources.
- `held` (still during `migrate`): staged commit sets `controller.replicas: 1`
  plus the migration-hold values from `checkpoints/held-values.yaml`; same
  `--resource` sync.

Rerun the same command after each checkpoint. When `migrate` finishes:

```sh
./api-migration status --state migration-state
kubectl get openbaoclusters.kubebao.org -A
```

Require `Phase: Verified`, operations hold `true`. The OpenBao pods roll once
to the 0.7.0 template here (3 voters, quorum kept; clients may see errors for
a few seconds per pod). Then commit; the first accepted source deletion
closes rollback permanently:

```sh
./api-migration commit --state migration-state --timeout "$MIGRATION_TIMEOUT"
```

`normal` checkpoint: staged commit removes the hold and replicas overrides
(exact 0.7.0 chart values), `--resource` sync of the named Deployments, rerun
`commit`. Require `Phase: Complete`, hold `false`.

## Convert Git and hand back to Argo CD

```sh
./api-migration convert --write platform/openbao/openbaocluster.yaml
git diff platform/openbao/   # apiVersion + kubebao.org-only changes; openbao.org/ labels stay
```

Merge order, with children still suspended:

1. This branch (CR conversion + `kubebao.org` schemas).
2. Renovate PR #703 (chart 0.7.0, OpenBao 2.7.3, pi 1.6.0). Rebase it onto
   the converted CR if it conflicts.
3. Revert the `bootstrap` ApplicationSet patch (Terraform owns it; a pushed
   change goes through Atlantis).

Then parent inward without pruning: the imported CRs lack the source
tracking metadata, so Argo CD shows OutOfSync until a first sync adds it.

```sh
argocd app sync appset-platform || argocd app sync platform   # parent
argocd app sync openbao-operator
argocd app sync openbao
```

Wait: after the merge of the CR bump, the operator rolls the OpenBao pods a
second time (2.7.2 → 2.7.3 upgrade orchestration). Check
`kubectl -n openbao get openbaoclusters.kubebao.org openbao -o jsonpath='{.status.phase}'`
returns `Available` on 2.7.3 before restoring automation:

```sh
argocd app set openbao --sync-policy automated
argocd app set openbao-operator --sync-policy automated
argocd app set appset-platform --sync-policy automated || argocd app set platform --sync-policy automated
```

## Cleanup

Only after every `openbao.org` resource is gone from the cluster:

```sh
kubectl get openbaoclusters.openbao.org,openbaotenants.openbao.org,openbaorestores.openbao.org -A   # must be empty
kubectl delete crd openbaoclusters.openbao.org openbaotenants.openbao.org openbaorestores.openbao.org
```

Then a follow-up commit removes `.kubeconform/openbao.org/`. Keep
`migration-state/` private (it holds the plan, values and Raft snapshots) and
revoke the token minted for `plan`.

## Rollback

While the rollback window is open (`status` shows it, before any source
deletion): keep everything suspended, push a git revert of any staged
checkpoint commits, then

```sh
./api-migration rollback --state migration-state --timeout "$MIGRATION_TIMEOUT"
```

`source` checkpoint: sync only the named resources at the original 0.6.3
values, rerun. Require `Phase: RolledBack`, follow
`migration-state/after-rollback.md`, restore `openbao.org/v1alpha1` in Git
(plain revert), hand back the same staged way as commit. The `kubebao.org`
CRDs stay installed.
