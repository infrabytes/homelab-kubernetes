# Gateway API CRDs: the subset Cilium 1.20 requires (see Cilium docs). Fetched
# from a pinned gateway-api release, embedded as a Talos controlplane inline
# manifest (applied at bootstrap, before the Cilium manifest) and converged by
# converge.tf so version bumps reach a running cluster. Fetching each CRD
# individually keeps the machine config far smaller than the full
# standard-install bundle.
#
# httproutes comes from the experimental channel: the HTTPRoute ExternalAuth
# filter (forward auth, platform/authentik/outpost-httproute.yaml) is an
# experimental GEP-1494 field and the standard CRD prunes it. The experimental
# CRD is a superset of the same v1 API, so the other kinds stay on standard.
locals {
  gateway_api_crd_kinds = [
    "gatewayclasses",
    "gateways",
    "httproutes",
    "referencegrants",
    "grpcroutes",
    "backendtlspolicies",
    "tlsroutes",
  ]
  gateway_api_crd_channels = {
    httproutes = "experimental"
  }
  gateway_api_crd_urls = {
    for kind in local.gateway_api_crd_kinds :
    kind => "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_crds_version}/config/crd/${lookup(local.gateway_api_crd_channels, kind, "standard")}/gateway.networking.k8s.io_${kind}.yaml"
  }
}

data "http" "gateway_api_crd" {
  for_each = toset(local.gateway_api_crd_kinds)
  url      = local.gateway_api_crd_urls[each.key]
}

locals {
  gateway_api_inline_manifest = join("\n---\n", [
    for kind in local.gateway_api_crd_kinds : data.http.gateway_api_crd[kind].response_body
  ])
}
