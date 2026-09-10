# tailscale-operator: Tailscale integration (tailnet proxy + API server proxy)

Deploys the Tailscale Operator (chart `tailscale-operator` from
`pkgs.tailscale.com/helmcharts`) with in-process API server proxy enabled.

## Prerequisites (Tailscale admin console)

1. Enable MagicDNS and HTTPS certificates on the tailnet.
2. Add tag owners: `tag:k8s-operator: ["autogroup:admin"]`,
   `tag:k8s: ["tag:k8s-operator"]`.
3. Create an OAuth client with write scope for General/Services, Devices/Core,
   Keys/Auth Keys (tagged `tag:k8s-operator`). Record the client ID and secret.
4. Merge ACL `grants` permitting `tcp:443` to `tag:k8s-operator` (and `tag:k8s`
   for the proxies).

## OAuth credentials flow

The operator's OAuth credentials are stored in OpenBao at `secret/tailscale-operator`
(keys: `client_id`, `client_secret`), written manually via `bao` CLI (see
openbao README). ESO syncs them into the `operator-oauth` Secret in the
`tailscale` namespace (creationPolicy: Owner).

After the operator chart first deploys, the pod crash-loops until ESO creates
the `operator-oauth` Secret — this is expected and self-heals within seconds.

## Tailnet hostnames

All exposure uses layer-7 `Ingress` resources (`ingressClassName: tailscale`):
the operator runs Tailscale Serve in a proxy pod and auto-provisions the
MagicDNS name + Let's Encrypt certificate declaratively — no Service
annotations, no manual `tailscale serve`.

- `openbao.<tailnet>.ts.net` — OpenBao UI/API
  (`platform/helm-charts/openbao/openbao-tailnet-ingress.yaml` → `openbao-active:8200`,
  plain HTTP backend; TLS terminates at the proxy).
- `dex.<tailnet>.ts.net` — second Dex instance for remote SSO
  (`platform/helm-charts/dex/dex-tailnet-ingress.yaml` → `dex-tailnet:5556`).
- `tailscale-operator.<tailnet>.ts.net` — API server proxy for kubectl.

In-cluster consumers reach the tailnet Dex through its own HTTPS listener
(the Terraform-generated cert in `dex-tailnet-tls`); see the openbao README.

## kubectl from the tailnet

```sh
tailscale configure kubeconfig https://tailscale-operator.<tailnet>.ts.net
kubectl get nodes
```

The owner's Tailscale identity is bound to `cluster-admin` via the
`ts-cluster-admin` ClusterRoleBinding in `platform/tailscale-rbac/`.

## Files

- `application.yaml` — ArgoCD Helm chart app (tailscale-operator 1.102.3,
  `apiServerProxyConfig.mode: "true"`).
- `external-secret.yaml` — ESO ExternalSecret (`operator-oauth` from OpenBao).
- `namespace.yaml` — `tailscale` namespace with `pod-security.kubernetes.io/enforce: privileged`
  (proxy pods run privileged; Talos's default baseline PSA rejects them otherwise).
