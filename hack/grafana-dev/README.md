# Grafana dev sandbox

Disposable Grafana on `http://127.0.0.1:33000` for authoring dashboards against
real data before exporting them into the repo's ConfigMap-backed
`GrafanaDashboard` CRs. Prod parity by construction: the image tag is resolved
from the live `grafana-deployment`, the datasources mirror prod's names/UIDs
(`victoriametrics` default, `loki`) pointed at port-forwarded VictoriaMetrics and
Loki, and every ConfigMap-backed dashboard is preloaded in its folder.

Requirements: a running docker daemon, the admin kubeconfig (`KUBECONFIG`, else
`infra/cluster/artifacts/kubeconfig`), PyYAML, kubectl, curl.

## Commands

| Command | What it does |
|---|---|
| `./run.sh` | Starts the sandbox: resolves the image, forwards VictoriaMetrics/Loki, regenerates provisioning + dashboards, runs the container, waits for health. |
| `./sync-dashboards.py` | Refreshes `generated/dashboards/` from the cluster's ConfigMap-backed CRs (run.sh does this on start). |
| `./export-dashboard.py <uid> <yaml>` | Fetches the dashboard's current JSON from the sandbox and writes it back into its ConfigMap, flipping the `resyncPeriod` (`1h`↔`59m`) so grafana-operator re-reads it. |
| `./stop.sh` | Removes the container and only the port-forwards it started. |

Environment overrides: `GRAFANA_DEV_HTTP_PORT` (33000), `GRAFANA_DEV_VM_PORT`
(18428), `GRAFANA_DEV_LOKI_PORT` (13100), `GRAFANA_DEV_IMAGE`,
`GRAFANA_DEV_CONTAINER`, `GRAFANA_DEV_URL`, `KUBECONFIG`.

`run.sh` refuses to start if any of its ports is already taken — other
sessions' port-forwards live on the defaults (18428, 13000) and are never
co-opted; pick other ports or stop the owner first. `stop.sh` never touches
forwards it did not start.

## Authoring loop

1. `./run.sh`, then browse `http://127.0.0.1:33000` (anonymous admin; Pi can
   drive it with `pi-browser-use`).
2. Edit or create a dashboard in the UI. Provisioned dashboards stay editable
   while the file on disk is unchanged.
3. `./export-dashboard.py <uid> <dashboards-file.yaml>` writes the sandbox
   version back: the file diff is exactly the ConfigMap block plus the
   `resyncPeriod` flip. The first export of a dashboard that predates it
   rewrites the JSON in the current Grafana key order (the stored files were
   written by an older schema), so review the whole block once; later exports
   carry only real changes.
4. Branch, PR, merge; grafana-operator reconciles the dashboard into prod.

Only ConfigMap-backed dashboards can be exported: CRs sourced from `url`,
`grafanaCom` or `oci` are skipped by `sync-dashboards.py` and rejected by
`export-dashboard.py`.

## Generated state

`generated/` is disposable (gitignored): `provisioning/` (datasources +
dashboard provider), `dashboards/` (the preloaded JSON, `generated/dashboards/
<folder>/<name>.json`), and `forwards/` (pidfiles/logs of the owned
port-forwards). Delete it for a clean slate; `run.sh` rebuilds everything.

The sandbox is read-path only against the cluster — it never writes to
VictoriaMetrics, Loki or any Kubernetes object.
