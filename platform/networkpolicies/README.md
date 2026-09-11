# NetworkPolicies

Supplemental network policies that chart values cannot express, plus the
per-namespace ingress default-denies that make the charts' port-scoped allows
binding.

## Posture

Every covered namespace ends up with:

1. its chart's own network policies, enabled through the chart's values;
2. a committed `default-deny-ingress` NetworkPolicy (`podSelector: {}`,
   `policyTypes: [Ingress]`) — that is what makes the chart's port list binding,
   since undeclared ports are otherwise reachable from any source;
3. egress restricted per pod from observed flows: chart values where they exist,
   Cilium policies only for edges a plain NetworkPolicy cannot name;
4. hand-written supplements in this directory — one policy per file — for
   anything the chart's values cannot express.

## Verified rules (each one cost a drop review)

**Policies match the post-DNAT pod and port, in both directions.** For traffic to
a Service, ingress *and* egress rules are evaluated against the backend pod and
its container port, never the Service's frontend port. An egress rule toward a
Service must therefore allow its `targetPort`, and a named port resolves against
the destination pod's container ports. Example: the `kubernetes` Service
advertises 443, yet API traffic has to be allowed on 6443.

**The Cilium Gateway is a hop in the datapath, not a peer.** Its envoy is a
host-network DaemonSet carrying the reserved `ingress` identity and enforces
network policy itself:

- rules with a `from` selector (`namespaceSelector`, `podSelector`) can never
  match it — the Gateway needs `fromEntities: [ingress]`
  (`openbao-allow-gateway-ingress.yaml`);
- for a request going *through* the Gateway, the client's egress policy is
  enforced against the HTTPRoute's backend pod and pod port, so rules aimed at
  the VIP or the node are inert. `openbao-allow-gateway-egress.yaml` existed for
  exactly that reason and was deleted; the rule that matters is the dex pod on
  5556, declared in the chart values.

**Kubelet probes need no allow.** Cilium adds an automatic
`Allow Ingress reserved:host ANY` entry to every endpoint, so a default-deny
cannot break liveness or readiness checks.

**Chart ingress rules select pods, not identities.** A rule like
`from: [{namespaceSelector: {}}]` reads as "allow everything" but only matches
*pods in namespaces* — it cannot match host-network peers such as the Gateway.
Port-scoped rules (ports, no `from`) are the ones that keep API-server and
gateway traffic working; see the cert-manager and external-secrets policies.

## Conventions

- One file per policy. Supplements are named `<workload>-allow-<what>.yaml`; the
  namespace default-deny is `<namespace>-default-deny-ingress.yaml` with the
  object name `default-deny-ingress`.
- Policies here are **additive**: Kubernetes NetworkPolicies union, so a narrow
  allow supplements chart-rendered policies instead of restating them.
- Each file names the chart it supplements and why that chart's values could not
  express the rule.
- Reach for a CiliumNetworkPolicy only when the rule needs
  `toEntities`/`fromEntities` (`kube-apiserver`, `host`, `remote-node`,
  `ingress`); namespace and pod selectors with ports belong in a plain
  NetworkPolicy.

## Covered namespaces (phase 1)

| Namespace | Chart values | Supplements here |
| --- | --- | --- |
| `dex` | dex `networkPolicy`: ingress ports, DNS + 443 egress | `dex-default-deny-ingress.yaml` |
| `dex-tailnet` | dex `networkPolicy` (adds the https listener) | `dex-tailnet-default-deny-ingress.yaml` |
| `cert-manager` | controller, webhook and cainjector `networkPolicy` | `cert-manager-default-deny-ingress.yaml` |
| `external-secrets` | controller, webhook and cert-controller `networkPolicy`: DNS, OpenBao 8200 | `external-secrets-allow-apiserver-egress.yaml`, `external-secrets-default-deny-ingress.yaml` |
| `openbao` | `server.networkPolicy`: DNS, raft 8201, both Dex backends | `openbao-allow-apiserver-egress.yaml`, `openbao-allow-gateway-ingress.yaml`, `openbao-default-deny-ingress.yaml` |
| `hubble-observer` | `ciliumNetworkPolicy`: relay egress, cf2cnp ingress with the `ingress` entity | `hubble-observer-allow-relay-egress.yaml`, `hubble-observer-allow-dns-egress.yaml`, `hubble-observer-default-deny-ingress.yaml` |
| `longhorn-system` | longhorn's internal policies (`restrictInternalTraffic`) | `longhorn-manager-allow-metrics.yaml` |

Known gaps inside covered namespaces:

- cert-manager's one-shot `startupapicheck` hook Job has no network-policy
  values and is not selected by the chart's podSelectors.
- The dex chart hardcodes its ingress port list, so its ingress cannot be
  source-restricted through values.
- Ingress stays source-unrestricted on declared ports by design; tightening
  it needs `fromEntities` for API-server and Gateway traffic and is a later
  phase.

## Phase 2 backlog

- **vcluster** — the chart's `policies.networkPolicy` was enabled in #172 and
  reverted in #174. The control plane's own bootstrap hook (`ensure protection
  policy: apply vcluster-protected-apiservices`) times out while the *nested*
  API server never passes `rbac/bootstrap-roles`, and the failure is identical
  with the policies removed. Re-attempt with a bisect (default-deny first, then
  the chart policies) once the CP starts cleanly.
- Rung 2, chart-value workloads: `external-dns`, the k8s-monitoring stack
  (`alloy-metrics`, `alloy-logs`, `kube-state-metrics`, `node-exporter`),
  `spegel`, both ARC charts, longhorn's manager and CSI metrics edges.
- Rung 3, raw manifests: `metrics-server`, `kubelet-serving-cert-approver`, and
  `kube-system` (cilium, coredns, hubble-relay, the Gateway's envoy).
- Rung 4: a `CiliumClusterwideNetworkPolicy` default-deny.
- `argocd`: tighten `argocd-server`'s allow-all ingress and restrict the
  repo-server's egress. That needs `global.networkPolicy.create: false` plus
  per-component re-enables in `infra/addons/main.tf`, then a manual
  `terragrunt apply` — which is why it is not part of phase 1.
- Namespace-level egress default-denies (phase 1 restricts egress only where a
  chart's policy selects pods).
- Tenant namespaces (`charts/tenant-access`, `pdeu`) and the unmanaged
  namespaces (`pi-sandbox`, `kagent`, `agent-sandbox-system`).
- Coverage enforcement as Kyverno policies (a covered namespace that loses its
  default-deny should fail admission) rather than a bespoke pre-commit hook.
