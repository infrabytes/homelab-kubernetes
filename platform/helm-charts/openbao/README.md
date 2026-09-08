# OpenBao

Cluster secrets manager (CNCF sandbox, Vault fork). HA raft — 3 replicas, one
per worker — with Longhorn PVCs and the built-in static-key auto-unseal.

- Chart app: `application.yaml` (openbao/openbao `0.29.4`, Renovate-tracked).
- Namespace + seal-key Secret (`openbao-seal`): created by Terraform
  (`infra/addons/main.tf`) from `infra/secrets.sops.yaml` — keys never appear
  in manifests.
- LAN-only access: `apps/openbao/route.yaml` (gateway `openbao-https` listener,
  cert-manager DNS-01 cert like argocd); plaintext http redirects to https
  (`apps/openbao/redirect.yaml`).
- Metrics: chart ServiceMonitor scraped by the k8s-monitoring stack.

## How auto-unseal works

`seal "static"` reads the 32-byte key from `/openbao/seal/current.key`
(file:// reference in the raft config; the Secret `current.key` holds the raw
bytes, TF decodes the base64 SOPS value). Every replica unseals itself on
start; the raft `retry_join` stanzas make followers join the cluster after
openbao-0 is initialized. No external unseal tooling.

Security tradeoff: any cluster-admin (or pod-exec) can read the seal key. This
is the accepted trust model — OpenBao chains to the cluster + SOPS as the
existing source of trust (static seal docs explicitly recommend this only when
such a source exists).

## Bootstrap (one-time)

Cluster must be reachable (`kubectl get nodes`), addons applied, and the chart
synced (`openbao-app` Healthy in ArgoCD):

```sh
kubectl port-forward -n openbao svc/openbao-active 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200

bao operator init -recovery-shares=0
#   OpenBao >= 2.4: no unseal keys (static seal), no recovery keys.
#   → JSON with the root token. If the CLI rejects 0 shares:
#   -recovery-shares=1 -recovery-threshold=1 and store the single recovery
#   key in SOPS too.
```

Store the root token in `infra/secrets.sops.yaml` (`openbao_root_token`, edit
via `sops`), then `cd infra && terragrunt apply --addons` so the value lands in
Terraform state (nothing in the cluster depends on it).

Then configure basics inside the cluster (root token stays there; the SA JWT
is read from the pod itself):

```sh
kubectl exec -n openbao openbao-0 -- sh -c '
  export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<root-token>
  bao secrets enable -path=secret kv-v2
  bao policy write openbao-admin - <<'EOF'
path "*" { capabilities = ["create", "read", "update", "delete", "list", "patch", "sudo"] }
EOF
  bao auth enable kubernetes
  bao write auth/kubernetes/config \
    kubernetes_host=https://kubernetes.default.svc \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
'
```

Notes:

- `token_reviewer_jwt` is the OpenBao SA's own JWT — the chart's
  `openbao-server-binding` ClusterRoleBinding (system:auth-delegator) authorizes
  the TokenReview call. It is a projected SA token: **every StatefulSet pod
  roll invalidates it**, breaking k8s-auth logins (`permission denied`) until
  the config is refreshed:

  ```sh
  kubectl exec -n openbao openbao-0 -- sh -c '
    export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=<root-token>
    bao write auth/kubernetes/config \
      kubernetes_host=https://kubernetes.default.svc \
      token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
  '
  ```
- `openbao-admin` is deliberately root-equivalent (single-admin homelab);
  consumers later get least-privilege roles.
- The route is LAN-only; `bao.icaninto.space` resolves to the cluster gateway
  L2 IP (RFC1918). Keep the Cloudflare record DNS-only (proxying blocks
  RFC1918 origins).

## Seal key rotation

Generate a new key, add it as a second Secret key and rotate via the static
seal's previous/current mechanism (docs:
<https://openbao.org/docs/configuration/seal/static/>):

1. `openssl rand -base64 32` → new SOPS value; add `previous.key` to the
   `openbao-seal` Secret with the old key (`binary_data` in `infra/addons`).
2. Config: `previous_key_id`/`previous_key` `file://` references alongside the
   new `current_key` (bump the `current_key_id`), then restart the StatefulSet.
3. Re-encrypt happens on restart; remove `previous_*` after a full seal cycle.
