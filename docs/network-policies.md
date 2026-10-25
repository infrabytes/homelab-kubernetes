# NetworkPolicies

Supplemental network policies that chart values cannot express, plus the
per-namespace ingress default-denies that make the charts' port-scoped allows
binding.

## Posture

Every covered namespace ends up with:

1. its chart's own network policies, enabled through the chart's values;
2. a committed `default-deny-ingress` NetworkPolicy (`podSelector: {}`,
   `policyTypes: [Ingress]`); that is what makes the chart's port list binding,
   since undeclared ports are otherwise reachable from any source;
3. egress restricted per pod from observed flows: chart values where they exist,
   Cilium policies only for edges a plain NetworkPolicy cannot name;
4. hand-written supplements next to their component (`platform/<component>/`),
   one policy per file, for anything the chart's values cannot express.

## Verified rules

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
  match it: the Gateway needs `fromEntities: [ingress]`
  (`openbao-allow-gateway-ingress.yaml`);
- for a request going *through* the Gateway, the client's egress policy is
  enforced against the HTTPRoute's backend pod and pod port, so rules aimed at
  the VIP or the node are inert. What keeps the LAN Dex reachable is the dex pod
  on 5556, declared in the chart values;
- a pod that *calls out* through the Gateway (Headlamp, OpenBao fetching the
  Authentik issuer) is authorized against the backend pod's identity, and only
  a Cilium rule matches that: a plain NetworkPolicy on the backend pods, a
  `toCIDR` on the VIP and `toEntities: [ingress]` are each denied with envoy's
  403 `Access denied` (`headlamp-allow-authentik-egress.yaml`; OpenBao's
  `toEntities: [ingress]` rule still needs the same fix).

**Kubelet probes need no allow.** Cilium adds an automatic
`Allow Ingress reserved:host ANY` entry to every endpoint, so a default-deny
cannot break liveness or readiness checks.

**Chart ingress rules select pods, not identities.** A rule like
`from: [{namespaceSelector: {}}]` reads as "allow everything" but only matches
*pods in namespaces*; it cannot match host-network peers such as the Gateway.
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
| `cert-manager` | controller, webhook and cainjector `networkPolicy` | `cert-manager-default-deny-ingress.yaml` |
| `external-secrets` | controller, webhook and cert-controller `networkPolicy`: DNS, OpenBao 8200 | `external-secrets-allow-apiserver-egress.yaml`, `external-secrets-default-deny-ingress.yaml` |
| `openbao` | `server.networkPolicy`: DNS, raft 8201 | `openbao-allow-apiserver-egress.yaml`, `openbao-allow-authentik-egress.yaml`, `openbao-allow-gateway-ingress.yaml`, `openbao-default-deny-ingress.yaml` |
| `headlamp` | — (the chart has no `networkPolicy` values) | `headlamp-default-deny-ingress.yaml`, `headlamp-allow-gateway-ingress.yaml`, `headlamp-allow-tailnet-ingress.yaml`, `headlamp-allow-egress.yaml` (DNS + the issuer's gateway VIP on 443), `headlamp-allow-authentik-egress.yaml` (Cilium: the identity rule to the Authentik server pods on 9000, without which the Gateway denies the issuer with 403), `headlamp-allow-apiserver-egress.yaml` |
| `hubble-observer` | `ciliumNetworkPolicy`: relay egress, cf2cnp ingress with the `ingress` entity | `hubble-observer-allow-relay-egress.yaml`, `hubble-observer-allow-dns-egress.yaml`, `hubble-observer-default-deny-ingress.yaml` |
| `vcluster` | `policies.networkPolicy`: chart defaults plus the metrics-server control-plane egress on 443/10250 | `vcluster-allow-host-dns-egress.yaml`, `vcluster-default-deny-ingress.yaml` |
| `longhorn-system` | longhorn's internal policies (`restrictInternalTraffic`) | `longhorn-manager-allow-metrics.yaml` |
| `alert-triage` | — (Argo Events renders no policies; the sandbox pods get a controller-managed policy from their `SandboxTemplate.spec.networkPolicy`: DNS, `grafana-mcp` 8000, Loki 3100 for the gates/memory, API server 6443, internet 443 for npm, models, Discord and GitHub; the breaking-change sandbox gets DNS and 443 only) | `alert-triage-default-deny-ingress.yaml`, `alert-triage-eventsource-allow-grafana-ingress.yaml`, `alert-triage-eventbus-allow-clients-ingress.yaml`, `alert-triage-eventsource-allow-egress.yaml`, `alert-triage-sensor-allow-egress.yaml`, `alert-triage-sensor-allow-apiserver-egress.yaml` (Cilium, API-server entity), `alert-triage-allow-monitoring-ingress.yaml` |
| `authentik` | — (the chart has no `networkPolicy` values) | `authentik-allow-gateway-ingress.yaml` (Cilium, `ingress` entity → 9000), `authentik-allow-metrics.yaml` (Alloy → 9300), `authentik-allow-egress.yaml` (Cilium: DNS, the in-namespace Postgres 5432, SMTP submission 587/465/2525, API server 443/6443 for the outpost controller) |

Known gaps inside covered namespaces:

- cert-manager's one-shot `startupapicheck` hook Job has no network-policy
  values and is not selected by the chart's podSelectors.
- `alert-triage`'s EventBus has no egress policy (NATS needs none) and the
  controller pod has no egress restriction yet; only the EventSource and Sensor
  are locked down, because their edges were known up front rather than audited.
- The dex chart hardcodes its ingress port list, so its ingress cannot be
  source-restricted through values.
- Ingress stays source-unrestricted on declared ports by design; tightening
  it needs `fromEntities` for API-server and Gateway traffic and is a later
  phase.
- `authentik` has no namespace-wide `default-deny-ingress`: its policies select
  the authentik pods, so the CloudNativePG instance sharing the namespace keeps
  its operator, backup and S3 edges, which are not modelled yet. Add the
  namespace deny together with those CNPG edges.

### vcluster control-plane note

Applying a policy change rolls the vcluster control plane, and that control plane
does not reliably survive a restart: the syncer's `ensure protection policy` hook
can stop completing (the nested API never reports ready through
`rbac/bootstrap-roles`) and the pod crash-loops with no ready endpoint. This is
**not** caused by these policies: reproduced with them absent, and again on a
fresh volume immediately after a single restart. Recovery is a destructive reset
of the `data-vcluster-0` PVC (clear its `pvc-protection` finalizer while the pod
is stopped); the StatefulSet then recreates the volume and the nested cluster
bootstraps fresh, after which the control plane runs until its next restart.

## Phase 2 backlog

- Rung 2, chart-value workloads: `external-dns`, the k8s-monitoring stack
  (`alloy-metrics` — including its static scrape of the PVE hosts'
  node_exporter on 192.168.0.11-14:9100 — `alloy-logs`,
  `kube-state-metrics`, `node-exporter`),
  `spegel`, both ARC charts, longhorn's manager and CSI metrics edges.
- Rung 3, raw manifests: `metrics-server`, `kubelet-serving-cert-approver`, and
  `kube-system` (cilium, coredns, hubble-relay, hubble-ui, the Gateway's envoy).
- Rung 4: a `CiliumClusterwideNetworkPolicy` default-deny.
- `argocd`: tighten `argocd-server`'s allow-all ingress and restrict the
  repo-server's egress. That needs `global.networkPolicy.create: false` plus
  per-component re-enables in `infra/addons/main.tf`, then a manual
  `terragrunt apply`. That is why it is not part of phase 1.
- Namespace-level egress default-denies (phase 1 restricts egress only where a
  chart's policy selects pods).
- Tenant namespaces (`charts/tenant-access`, `pdeu`) and the unmanaged
  namespaces (`pi-sandbox`, `kagent`, `agent-sandbox-system`).
- Coverage enforcement as Kyverno policies (a covered namespace that loses its
  default-deny should fail admission) rather than a bespoke pre-commit hook.
