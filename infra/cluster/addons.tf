# Gateway API CRDs — the subset Cilium 1.20 requires (see Cilium docs). These
# are bootstrap-time cluster resources: fetched from a pinned gateway-api
# release and embedded as a Talos controlplane inline manifest (applied at
# bootstrap, before the Cilium manifest). Fetching each CRD individually keeps
# the machine config far smaller than the full standard-install bundle.
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
  gateway_api_crd_urls = {
    for kind in local.gateway_api_crd_kinds :
    kind => "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_crds_version}/config/crd/standard/gateway.networking.k8s.io_${kind}.yaml"
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
