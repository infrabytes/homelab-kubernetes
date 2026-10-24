# Grafana MCP server

Chart app `grafana-mcp`, release `grafana-mcp` in `observability`
(`grafana-community/grafana-mcp`, pinned `targetRevision`). Streamable HTTP on
`/mcp` (port 8000; `/healthz` at the root); it talks to the local Grafana at
`grafana-service:3000`.

The `grafana/grafana-mcp` chart that would be the obvious source is deprecated
and bundles mcp-grafana 0.8.2, which predates caller auth (`--server-auth-token`),
`--allowed-hosts` and `--disable-api`. `grafana-community` is the maintained
continuation of the same chart and its appVersion tracks the image, so the
server version moves with the chart `targetRevision` under Renovate.

## Exposure and auth

LAN-only HTTPRoute at `grafana-mcp.icaninto.space` through the
`grafana-mcp-https` gateway listener (RFC1918 gateway IP — the Cloudflare record
must stay DNS-only). `/mcp` requires `Authorization: Bearer <caller token>` and
returns 401 without it; the header is stripped before any Grafana request. The
`/healthz` (and `/metrics`) ops endpoints stay unauthenticated at the server
root by upstream design — kubelet probes use `tcpSocket`, so nothing but the
MCP path needs the token anyway.

Read-only in depth: `disableWrite` (`--disable-write`) plus `--disable-api` keep
the mutating and raw-API tool groups out of the tool list, and the server's
Grafana service account holds only the Viewer role — a direct
`POST /api/dashboards/db` with that token gets 403.

`disabledCategories` drops the tool groups whose plugins (oncall, incident,
snapshot, asserts) and image renderer do not exist on this Grafana.
`--usage-stats=disabled` suppresses the upstream telemetry report.

Probes are `tcpSocket` because HTTP probes fail Host validation (kubelet sends
the pod IP as Host); `--allowed-hosts` replaces the loopback-only default that
`--address 0.0.0.0:8000` would otherwise imply. It lists both the LAN host and
`grafana-mcp.observability.svc.cluster.local:8000`, because the middleware
compares the `Host` header literally and the alert-triage sandbox
(`platform/alert-triage`) calls the Service directly from inside the cluster.

## Credentials

`grafana-mcp-credentials` in `observability` is Terraform-owned
(`infra/addons`), not ESO: keys `grafana-token` (the Grafana service account)
and `server-token` (the caller bearer token). Both live in
`infra/secrets.sops.yaml` as `grafana_mcp_service_account_token` and
`grafana_mcp_server_token`.

Create the service account once (Grafana has no IaC path for service accounts):

```sh
kubectl -n observability port-forward --address 127.0.0.1 svc/grafana-service 13300:3000
# SA:     POST /api/serviceaccounts {"name":"grafana-mcp","role":"Viewer","isDisabled":false}
# token:  POST /api/serviceaccounts/<id>/tokens {"name":"grafana-mcp-lan","secondsToLive":0}
```

Authenticate those calls with the Grafana admin break-glass credentials and
record the returned `key` as `grafana_mcp_service_account_token`. The caller
token is `openssl rand -hex 32`, stored as `grafana_mcp_server_token`.

Rotation is: mint the new value, `sops set --value-file`, PR (Atlantis applies
the Secret), then `kubectl -n observability rollout restart deploy/grafana-mcp`
— a Secret change alone does not roll the pods. Update Pi's config in the same
step when the caller token rotates.

## Pi wiring

`~/.config/mcp/mcp.json`:

```json
{
  "servers": {
    "grafana": {
      "url": "https://grafana-mcp.icaninto.space/mcp",
      "headers": { "Authorization": "Bearer ${GRAFANA_MCP_SERVER_TOKEN}" }
    }
  }
}
```

Export `GRAFANA_MCP_SERVER_TOKEN` from SOPS (or use the adapter's `!` command
form) rather than pasting the token into the file.

## Future: network policy

`observability` is not in the netpol phase-1 table, so this component adds no
policy work today. If a default-deny lands here, the pod needs ingress from the
gateway's `ingress` entity on 8000 and egress to `grafana-service:3000` plus DNS.
