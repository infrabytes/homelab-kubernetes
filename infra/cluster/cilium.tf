# Cilium CNI, rendered locally into a single manifest and embedded as a Talos
# controlplane inline manifest. Talos applies it automatically during bootstrap.
# See https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium/
#
# Certs are generated once (stored in state) and pinned via values to keep the
# chart render deterministic (see the values block below).
resource "tls_private_key" "cilium_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "cilium_ca" {
  private_key_pem   = tls_private_key.cilium_ca.private_key_pem
  is_ca_certificate = true

  subject {
    common_name  = "Cilium CA"
    organization = "homelab"
  }

  validity_period_hours = 87600

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "cert_signing",
  ]
}

resource "tls_private_key" "hubble_server" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "hubble_server" {
  private_key_pem = tls_private_key.hubble_server.private_key_pem

  subject {
    common_name = "*.default.hubble-grpc.cilium.io"
  }

  dns_names = ["*.default.hubble-grpc.cilium.io"]
}

resource "tls_locally_signed_cert" "hubble_server" {
  cert_request_pem   = tls_cert_request.hubble_server.cert_request_pem
  ca_private_key_pem = tls_private_key.cilium_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.cilium_ca.cert_pem

  is_ca_certificate = false

  validity_period_hours = 87600

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}

resource "tls_private_key" "hubble_relay_client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "hubble_relay_client" {
  private_key_pem = tls_private_key.hubble_relay_client.private_key_pem

  subject {
    common_name = "*.hubble-relay.cilium.io"
  }

  dns_names = ["*.hubble-relay.cilium.io"]
}

resource "tls_locally_signed_cert" "hubble_relay_client" {
  cert_request_pem   = tls_cert_request.hubble_relay_client.cert_request_pem
  ca_private_key_pem = tls_private_key.cilium_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.cilium_ca.cert_pem

  is_ca_certificate = false

  validity_period_hours = 87600

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "client_auth",
  ]
}

# `data.helm_template` renders the chart locally (ClientOnly dry-run, no cluster
# contact), so it works even though the cluster only exists after bootstrap.
data "helm_template" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_chart_version
  namespace  = "kube-system"
  # No cluster/kubeconfig exists at render time, so the provider would report a
  # default Kubernetes version too low for Cilium's kubeVersion constraint. Pin
  # it to the cluster's actual version (used for Capabilities.KubeVersion only).
  kube_version = var.kubernetes_version

  # Cilium's CRDs ship in the chart's crds/ dir, which a plain `helm template`
  # omits; the Talos inline manifest must include them so policies can apply.
  include_crds = true

  # Talos-specific values (Sidero docs, "without kube-proxy" variant): ipam
  # kubernetes (required by Talos), kubeProxyReplacement + KubePrism
  # (localhost:7445), L2 announcements, Gateway API. SYS_MODULE deliberately
  # absent (Talos forbids workload module loading); cgroup already mounted by
  # Talos. kube-proxy is fully replaced (cluster.proxy.disabled patched into
  # the machine config in module talos-cluster).
  values = [<<-EOT
    ipam:
      mode: kubernetes
    kubeProxyReplacement: true
    k8sServiceHost: localhost
    k8sServicePort: 7445
    l2announcements:
      enabled: true
    gatewayAPI:
      enabled: true
      enableAlpn: true
      enableAppProtocol: true
    # WireGuard encryption (pod-to-pod + node-to-node). Talos ships
    # CONFIG_WIREGUARD=y and keys are generated at agent runtime, so the render
    # stays deterministic.
    encryption:
      enabled: true
      type: wireguard
      nodeEncryption: true
    # Hubble mTLS certs are pinned explicitly: with hubble.tls.auto on, the chart
    # generates a fresh CA + server cert on every render (no cluster to look up
    # existing secrets from), making the output non-deterministic.
    tls:
      ca:
        cert: ${base64encode(tls_self_signed_cert.cilium_ca.cert_pem)}
        key: ${base64encode(tls_private_key.cilium_ca.private_key_pem)}
    # Serves cilium_* agent metrics on :9962 (hostPort). The chart's
    # ServiceMonitors are the collection path: they carry the k8s_app /
    # io_cilium_app target labels the dashboards filter on, and keep only
    # local.cilium_dashboard_families.
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: true
        # The chart render is local (no cluster to validate the CRDs against).
        trustCRDsExist: true
        metricRelabelings:
          - action: keep
            sourceLabels: [__name__]
            regex: "${join("|", local.cilium_dashboard_families)}"
    # Six dashboard ConfigMaps (agent, operator, four Hubble) land in
    # kube-system; platform/grafana-dashboards imports them into the stack.
    dashboards:
      enabled: true
    hubble:
      # Hubble metrics on :9965 (hostPort), scraped through the same PodMonitor:
      # flow/drop/tcp = verdicts, reasons, flags, dns/http/icmp = the matching
      # dashboard panels; namespace context labels only (the two namespace
      # dashboards group by them - workload/pod labels would add thousands of
      # series, so the L7-by-workload dashboard stays empty).
      # port-distribution is off: 649 series for one panel, and the 2026-09-12
      # series triage (steady state 9.5K vs the 9000-series alert) chose the trim.
      metrics:
        enabled:
          - flow:labelsContext=source_namespace,destination_namespace
          - drop:labelsContext=source_namespace,destination_namespace
          - tcp:labelsContext=source_namespace,destination_namespace
          - dns:labelsContext=source_namespace,destination_namespace
          - http:labelsContext=source_namespace,destination_namespace
          - icmp:labelsContext=source_namespace,destination_namespace
        dashboards:
          enabled: true
        serviceMonitor:
          enabled: true
          trustCRDsExist: true
      tls:
        auto:
          enabled: false
        server:
          cert: ${base64encode(tls_locally_signed_cert.hubble_server.cert_pem)}
          key: ${base64encode(tls_private_key.hubble_server.private_key_pem)}
      relay:
        enabled: true
        tls:
          client:
            cert: ${base64encode(tls_locally_signed_cert.hubble_relay_client.cert_pem)}
            key: ${base64encode(tls_private_key.hubble_relay_client.private_key_pem)}
        # Sizing baseline 2026-08-27..09-10 (Grafana Cloud, 13d22h): memory request = p95
        # rounded up to 64Mi (32Mi floor), limit = max(1.5x request, 1.25x peak); CPU requests only.
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            memory: 96Mi
    # Leader-election client rate limit for L2 announcement leases
    # (docs sizing: #services / leaseRenewDeadline; homelab small -> 16/32).
    k8sClientRateLimit:
      qps: 16
      burst: 32
    # Sizing baseline 2026-08-27..09-10 (Grafana Cloud, 13d22h): memory request = p95
    # rounded up to 64Mi (32Mi floor), limit = max(1.5x request, 1.25x peak); CPU requests only.
    resources:
      requests:
        cpu: 140m
        memory: 448Mi
      limits:
        memory: 672Mi
    operator:
      dashboards:
        enabled: true
      prometheus:
        serviceMonitor:
          enabled: true
          trustCRDsExist: true
          metricRelabelings:
            - action: keep
              sourceLabels: [__name__]
              regex: "${join("|", local.cilium_dashboard_families)}"
      resources:
        requests:
          cpu: 20m
          memory: 192Mi
        limits:
          memory: 288Mi
    envoy:
      resources:
        requests:
          cpu: 20m
          memory: 64Mi
        limits:
          memory: 96Mi
    securityContext:
      capabilities:
        ciliumAgent:
          - CHOWN
          - KILL
          - NET_ADMIN
          - NET_RAW
          - IPC_LOCK
          - SYS_ADMIN
          - SYS_RESOURCE
          - DAC_OVERRIDE
          - FOWNER
          - SETGID
          - SETUID
        cleanCiliumState:
          - NET_ADMIN
          - SYS_ADMIN
          - SYS_RESOURCE
    cgroup:
      autoMount:
        enabled: false
      hostRoot: /sys/fs/cgroup
  EOT
  ]
}
