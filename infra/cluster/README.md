# Homelab Kubernetes

Talos Linux Kubernetes cluster on Proxmox VE, managed by **Terragrunt/OpenTofu**
(see [`../README.md`](../README.md) for the Terragrunt workflow and SOPS/AGE
secrets). This unit (`infra/cluster`) provisions the cluster; the ArgoCD GitOps
bootstrap lives in `../addons`.

Non-secret inputs are in `terragrunt.hcl`; the secret (`proxmox_api_token`) is
in the shared SOPS-encrypted `../secrets.sops.yaml`.

## Overview

- **Proxmox side** (`bpg/proxmox`): downloads each node's Talos ISO straight onto
  the target node's datastore via the PVE *download-url* API, then creates UEFI
  (`ovmf`/q35) VMs booting from that ISO.
- **Image Factory** (`talos_image_factory_schematic`): one content-addressed
  schematic per node, baking in the system extensions and a static `ip=`
  kernel argument. The node's maintenance mode thus comes up directly at its
  configured IP.
- **Talos side** (`siderolabs/talos`): generates machine secrets + per-node
  machine configs, applies them over the maintenance service (installing Talos
  to disk), upgrades nodes in place when `talos_version` changes
  (`talos_machine`), bootstraps the cluster and rolls Kubernetes when
  `kubernetes_version` changes (`talos_cluster`), and writes out
  `artifacts/kubeconfig` and `artifacts/talosconfig`.
- **Cilium CNI** (`hashicorp/helm`): the Cilium Helm chart is rendered locally
  into a single manifest, disabled Talos's default Flannel
  (`cluster.network.cni.name: none`), and embeds the manifest as a controlplane
  **inline manifest** that Talos applies automatically during bootstrap.

## Layout

| File                     | Purpose                                                       |
| ------------------------ | --------------------------------------------------------------|
| `versions.tf`            | Provider pins + optional state backend                        |
| `providers.tf`           | `bpg/proxmox` + `siderolabs/talos` + `hashicorp/helm`         |
| `variables.tf`           | Cluster / version / storage / network variables               |
| `cilium.tf`              | Renders the Cilium chart via `data.helm_template`             |
| `nodes.tf`               | Node definitions (IP-keyed; role, sizing, VM IDs)             |
| `schematics.tf`          | Per-node Image Factory schematics (extensions + ip=)          |
| `main.tf`                | Composes the two modules                                      |
| `locals.tf`              | Derived ISO URLs + per-module node field subsets              |
| `modules/proxmox-node/`  | Reusable module: per-node ISO download + VM resources         |
| `modules/talos-cluster/` | Reusable module: secrets, per-node configs, `talos_machine` (apply + OS upgrade), `talos_cluster` (bootstrap + k8s upgrade) |
| `terragrunt.hcl`         | Inputs (cluster/node/version settings; points at SOPS secret) |

## Prerequisites

1. `terragrunt` and OpenTofu (≥ 1.11) on the machine running this. `talosctl`
   is only needed for debugging/manual node operations; upgrades and config
   changes are provider-driven.
2. A Proxmox API token. bpg provider needs (at least) `Datastore.AllocateTemplate`
   plus `Sys.Audit`/`Sys.Modify` for the ISO download, and VM permissions
   (`VM.Allocate`, `VM.Config.*`, `VM.PowerMgmt`, ...). See the provider's
   ["API Token Authentication" docs](https://bpg.sh/docs/#api-token-authentication).
   Simpler for a homelab: use `root@pam` username/password.
3. **Internet access to Image Factory** (`factory.talos.dev`) from the machine
   running Terraform (per-node schematics + ISO downloads). Only extensions and
   kernel arguments are sent to the factory, cluster secrets stay local.
4. Use the **standard** (non-secureboot) Talos ISO for Proxmox. Talos Secure
   Boot requires Sidero-signed OVMF firmware; the plain Proxmox OVMF can't boot
   the `metal-amd64-secureboot.iso`. Keep `secure_boot = false` unless you've
   installed that firmware.

## Usage

Values live in `terragrunt.hcl` (non-secret) and `../secrets.sops.yaml`
(secret, SOPS-encrypted). Run from this directory, or the whole stack from
`../` with `--all`:

```sh
terragrunt plan
terragrunt apply
# from infra/: terragrunt apply --all
```

### ISO lifecycle

ISOs are content-addressed (`talos-<hostname>-<schematic-id-prefix>-<version>.iso`)
and managed by `proxmox_download_file` with `overwrite = true`. Normal
`terragrunt apply` runs never re-download an unchanged ISO. The download
resource is only replaced when its URL (i.e. the schematic/config) changes.

A full `terragrunt destroy` *does* delete the ISOs (they're managed
resources), so the next apply re-downloads them. To rebuild the nodes without
touching the ISOs (or the cluster identity), replace just the VMs and the apply
resources instead:

```sh
terragrunt apply \
  -replace='module.proxmox_nodes.proxmox_virtual_environment_vm.node["192.168.0.67"]' \
  -replace='module.talos_cluster.talos_machine_configuration_apply.this["192.168.0.67"]'
# ...repeat for each node IP
```

After apply:

```sh
export KUBECONFIG="$PWD/artifacts/kubeconfig"
kubectl get nodes
# talosctl --talosconfig artifacts/talosconfig -n <ip> get machinestatus
```

The apply flow: machine secrets + machine configs are generated; per-node
schematics bake system extensions and a static `ip=` kernel argument into each
node's ISO (`schematics.tf`). Proxmox downloads the ISOs and creates the VMs.
Each VM boots into maintenance mode **at its static IP** (kernel arg), the
`talos_machine` resource installs Talos to disk, and the
node reboots into the cluster config. `talos_cluster` then bootstraps etcd
(idempotent, retries while the controlplane finishes installing), waits for the
etcd/apiserver layer, and the kubeconfig is written. On later applies
`talos_machine` also upgrades the node's OS when the declared installer image
changes (see [Upgrades](#upgrades-talos--kubernetes)). VMs are left with
`boot_order = [scsi0, ide2]` so they boot from disk on reboot (the ISO only
installs once).

> **First apply on an existing misprovisioned cluster:** destroy the VMs first
> (`terragrunt destroy`). Fresh disks are required for a clean install.

### Scaling up

Add another entry (with a free IP and unique `vm_id`) to the `nodes` map in
`terragrunt.hcl`, then `terragrunt apply`. New workers join automatically.

## Cilium CNI (instead of Flannel)

The cluster uses Cilium as its CNI (Talos's default Flannel is disabled). Cilium
is delivered the way the
[Sidero docs recommend](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)
for production, as an **inline manifest**:

- `cluster.network.cni.name: none` is patched into **every** node's machine
  config, so Talos never installs Flannel.
- `cilium.tf` renders the Cilium Helm chart locally with `data.helm_template`
  from `hashicorp/helm`. This is a `ClientOnly` dry-run render (like
  `helm template`). The chart version is pinned by `cilium_chart_version` in
  `terragrunt.hcl`, and `kube_version` is set to the cluster's Kubernetes
  version so the chart's `kubeVersion` check passes pre-bootstrap.
- The rendered manifest becomes a controlplane **inline manifest**
  (`cluster.inlineManifests[].cilium`). Talos applies it itself during
  bootstrap, so **no manual `helm install`/`kubectl apply` window** is needed.

Upgrade Cilium: bump `cilium_chart_version` → `terragrunt apply` (re-renders
the manifest and re-applies the controlplane config).

> Change only the values in `cilium.tf`'s `values` block to enable extras
> (e.g. Hubble `hubble.enabled=true`, or kube-proxy-free), then re-apply.

## Upgrades (Talos & Kubernetes)

Both upgrades are driven by the Terraform code: bump `talos_version` /
`kubernetes_version` in `env.hcl` (Renovate does this) and the next
`terragrunt apply` performs them. There is no manual `talosctl upgrade` /
`upgrade-k8s` step, and upgrades need no new ISOs: they are in-place, and
per-node ISOs are only for fresh installs (they re-download automatically on
version bumps).

- **Talos OS** — `talos_machine` (one per node) keeps the running version in
  sync with the installer image: `image` = the node's `machine.install.image`,
  both derived from `talos_version` + the node's schematic. When it changes,
  the node is upgraded in place first (pull installer → install to disk →
  cordon+drain → reboot → wait for health → uncordon) and only then the
  regenerated machine config is applied, so the upgraded node validates
  the new config instead of the old one rejecting it. Controlplane nodes go
  first, then workers one at a time (`-parallelism=1` is injected into `apply`
  by the unit's `terragrunt.hcl`: parallel worker reboots would take all
  Longhorn replicas down at once).
- **Kubernetes** — `talos_cluster.kubernetes_version` runs Talos's
  `upgrade-k8s` procedure: sequential control-plane component upgrades with
  health gating, kubelet node-by-node, CoreDNS/kube-proxy manifests.
  `ignore_kubernetes_upgrade_drift = true` on `talos_machine` keeps the
  config-apply path out of the way (a `kubernetes_version` bump does not
  re-apply machine configs; `talos_cluster` owns it). `kubernetes_version`
  in `data.talos_machine_configuration` still pins the image tags that new
  nodes bootstrap with; keep both on the same value (they come from the same
  `env.hcl` input). Bumping Talos and Kubernetes in the same apply (Renovate
  may ship them together) is fine: OS upgrades land first, then the
  Kubernetes rolling upgrade.
- **Drift** — every plan/refresh reads each node's running Talos version and
  applied-config hash. Manual `talosctl upgrade`/config edits surface as drift
  and the next apply reconciles them to the declared version, up or down.

Talos rules still apply: only **adjacent minor** OS upgrades (step through
each minor's latest patch, don't skip minors), one Kubernetes minor at a time
(`upgrade-k8s` validates the path), and a joining node's kubelet must not
exceed the API server's minor.

> **Why this exists:** the previous flow only patched `machine.install.image`
> into the applied configs (`talos_machine_configuration_apply`), which
> upgrades nothing on a running node (the install image is only read at
> install time). Nodes silently stayed on the old Talos until a Kubernetes
> bump was rejected by the old OS with `version of Kubernetes ... is too new
> to be used with Talos ...`.
>
> The provider is pinned to the `0.12.0-beta.0` beta line (the first with
> `talos_machine`/`talos_cluster`); Renovate bumps the exact pin once a newer
> stable release lands.

## QEMU guest agent (optional)

To get clean guest shutdowns and IP reporting from inside Proxmox, Talos must be
installed with the `siderolabs/qemu-guest-agent` extension, **and** the guest
agent must be enabled on the VM.

1. Set `enable_qemu_guest_agent = true`. This appends
   `siderolabs/qemu-guest-agent` to `talos_system_extensions`, which get baked
   into every node's schematic/ISO. The *installed* system also needs the
   extension. It comes from the installer image written into
   `machine.install.image`, which is built from `talos_scheme_id`; make sure
   that scheme includes the extension too.
2. Add any other official extensions to `talos_system_extensions`
   (default: `["siderolabs/intel-ucode"]`).
3. `terragrunt apply`, then reprovision nodes whose images need the
   extension (`terragrunt destroy` + `apply`, or a manual `talosctl reset`).

> Only enable the guest agent when the extension is included; enabling it
> without the extension produces log spam and no functionality.

# External access (Cilium L2 LB + Gateway API)

Applications are exposed from the LAN via the networking stack this cluster
boots with (no separate ingress/load-balancer components):

- **kube-proxy-free**: machine configs set `cluster.proxy.disabled: true`.
  Cilium runs `kubeProxyReplacement: true` and talks to the API server through
  KubePrism (`localhost:7445`, on by default).
- **L2 announcements + LB-IPAM**: the Cilium chart enables
  `l2announcements.enabled`; a `CiliumLoadBalancerIPPool` elects addresses from
  `192.168.0.200-192.168.0.219` (must stay outside the router DHCP range) and a
  `CiliumL2AnnouncementPolicy` advertises them via ARP on the LAN.
- **Gateway API** (Envoy): the Cilium chart enables `gatewayAPI.*`; the Gateway
  API CRDs (pinned to the version Cilium 1.20 documents, `v1.6.1`) are fetched
  by `addons.tf` and embedded as a controlplane inline manifest **before** the
  Cilium manifest. A `Gateway` (`platform/network/gateway.yaml`) with fixed
  address `192.168.0.200` terminates HTTP/HTTPS; apps get `HTTPRoute`s.
- **TLS + DNS**: cert-manager (Let's Encrypt DNS-01 via Cloudflare) issues certs
  for LAN-only hostnames; external-dns creates/updates Cloudflare records from
  Gateways/HTTPRoutes. Both are GitOps-managed (see below).

> GitOps (ArgoCD) bootstrapping and app delivery are **not** part of this unit.
> See [`../addons/README.md`](../addons/README.md) (installs ArgoCD) and
> [`../argocd-config/README.md`](../argocd-config/README.md) (ApplicationSets for
> `platform/` + `apps/`).

# Spegel (P2P image mirroring)

[Spegel](https://spegel.app/) is a stateless OCI registry mirror that lets nodes
serve container images to each other over a libp2p mesh, cutting external
registry pulls and speeding up image distribution:

- **containerd keeps unpacked layers**: the machine config in
  `modules/talos-cluster/main.tf` writes `/etc/cri/conf.d/20-customization.part`
  with `discard_unpacked_layers = false`, so nodes have local layers to serve.
  `machine.files` is not apply-immediate, so the next `terragrunt apply` reboots
  each node automatically (default `apply_mode = auto`); the provider retries
  while the node comes back.
- **App deployment**: Spegel runs as a privileged DaemonSet, delivered by ArgoCD
  from `platform/helm-charts/spegel/` (OCI chart `ghcr.io/spegel-org/helm-charts/spegel`).
  It is pointed at Talos's non-default containerd config path
  (`spegel.containerdRegistryConfigPath: /etc/cri/conf.d/hosts`) so it can
  write the mirror configuration that containerd reads.
- **Pod Security**: the `spegel` namespace carries
  `pod-security.kubernetes.io/enforce: privileged` (Talos PSA defaults are
  restrictive; the DaemonSet mounts host paths and writes host config).

## Notes & pitfalls

- **Don't lose the machine secrets** (`talos_machine_secrets`). The `talosconfig`
  in `artifacts/` and your Terraform state both carry the secrets. Back up your
  `.tfstate` (ideally to a remote backend, see `versions.tf`) and
  `artifacts/talosconfig`. If the state is lost the cluster can't be re-adopted.
- `talos_machine_secrets` regenerates on every fresh `apply` run unless the
  resource is imported/kept in state. For a durable cluster, keep state or
  import the existing secrets. This scaffold keeps them in the (local) state.
- VMs force-stop on destroy (`stop_on_destroy = true`) unless the guest agent is
  enabled, which allows clean shutdowns (fine for worker/controlplane VMs that
  get re-applied).
- **Secure Boot is off** by default (`secure_boot = false`). The standard Talos
  `metal-amd64.iso` is used; Talos's `metal-amd64-secureboot.iso` requires the
  Sidero-signed OVMF firmware that plain Proxmox OVMF doesn't ship, and won't
  boot otherwise. Don't set `secure_boot = true` unless you've installed that
  firmware.
- **Stable IPs without DHCP reservations.** Each node's ISO carries a static
  `ip=` kernel argument (`schematics.tf`) so maintenance mode comes up at the
  node's configured IP, and the machine config pins the same static IP on the
  node's interface. Two naming gotchas are handled:
  - The `ip=` device must be `eth0` (`talos_maintenance_device`); that's the
    NIC's name at initramfs parse time; udev renames it to `ens18` seconds
    later, so `ens18`/`enx*` (or an empty device) silently fail to apply.
  - The machine config interface must be the **MAC-based name**
    (`enx<mac>`, derived from each node's pinned `mac_address`); the `eth0`
    alias doesn't survive the udev rename, but the MAC-based altname always
    resolves to the physical NIC.
  Note: `embeddedMachineConfiguration` in schematics is silently dropped by the
  released talos provider (image-factory < v1.3.3), so it is not used here;
  the `ip=` kernel argument achieves the same outcome through the officially
  supported `extraKernelArgs`.
- **Config changes and OS versions are managed by `talos_machine`.** Edits
  to node fields flow into the config patches and are re-applied to the running
  nodes on the next `terragrunt apply`. Each node's running Talos version and
  applied-config hash are read on every refresh; anything changed
  out-of-band is reconciled to the declared state on the next apply.
- **Bootstrap pauses at phase 18/19 ("node not ready").** Expected with
  `cni: none`; nodes can't become Ready until a CNI runs. Because Cilium is an
  inline manifest, Talos applies it itself during bootstrap; the
  `talos_cluster` resource retries internally. If an apply still ends
  not-ready, just re-run `terragrunt apply` (idempotent).
- **`cilium connectivity test` vs PodSecurity.** Test pods violate the
  `baseline` policy (they need `NET_RAW` in capabilities). Workaround: label the
  test namespace `pod-security.kubernetes.io/enforce=privileged`.
- **CoreDNS + `bpf.masquerade`.** Known Cilium-on-Talos issue only if you later
  enable `bpf.masquerade` while Talos's `forwardKubeDNSToHost` (default) is on,
  `bpf.masquerade` is off by default here.
