#!/usr/bin/env bash
# Disposable laptop-local Grafana for dashboard authoring; state lives in generated/ (stop.sh undoes exactly that).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
generated="$here/generated"

container="${GRAFANA_DEV_CONTAINER:-grafana-dev-sandbox}"
http_port="${GRAFANA_DEV_HTTP_PORT:-33000}"
vm_port="${GRAFANA_DEV_VM_PORT:-18428}"
loki_port="${GRAFANA_DEV_LOKI_PORT:-13100}"
export KUBECONFIG="${KUBECONFIG:-$repo_root/infra/cluster/artifacts/kubeconfig}"

fail() {
  echo "run.sh: $*" >&2
  "$here/stop.sh" >/dev/null 2>&1 || true
  exit 1
}

# Never leave a half-started sandbox behind (container up, its forwards dead).
cleanup_on_error() {
  local rc=$?
  echo "run.sh: failed (exit $rc), tearing down what it started" >&2
  "$here/stop.sh" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup_on_error ERR

port_listening() { ss -ltnH "sport = :$1" | grep -q .; }

[[ -r "$KUBECONFIG" ]] || fail "admin kubeconfig not readable: $KUBECONFIG (set KUBECONFIG)"
command -v kubectl >/dev/null || fail "kubectl is not on PATH"
command -v docker >/dev/null || fail "docker is not on PATH"
docker info >/dev/null 2>&1 || fail "docker daemon is not running"
kubectl -n observability get deploy grafana-deployment >/dev/null \
  || fail "cannot read grafana-deployment with $KUBECONFIG"

docker ps -a --format '{{.Names}}' | grep -qx "$container" \
  && fail "container $container already exists; ./stop.sh first"

# Other sessions leave port-forwards on the default ports; never co-opt them.
for p in "$http_port" "$vm_port" "$loki_port"; do
  port_listening "$p" \
    && fail "port $p is already in use (try: ss -ltnp | grep $p); free it or pick another via GRAFANA_DEV_*_PORT"
done

image="${GRAFANA_DEV_IMAGE:-$(kubectl -n observability get deploy grafana-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].image}')}"
[[ -n "$image" ]] || fail "could not resolve the Grafana image from grafana-deployment"

mkdir -p "$generated/forwards" "$generated/provisioning/datasources" "$generated/provisioning/dashboards"

"$here/sync-dashboards.py"

kubectl -n observability get cm grafana-datasources -o jsonpath='{.data.datasources\.yaml}' \
  > "$generated/datasources-prod.yaml"
python3 - "$generated/datasources-prod.yaml" "$vm_port" "$loki_port" \
  > "$generated/provisioning/datasources/datasources.yaml" <<'PY'
import sys, yaml
vm_port, loki_port = sys.argv[2], sys.argv[3]
urls = {"victoriametrics": f"http://127.0.0.1:{vm_port}", "loki": f"http://127.0.0.1:{loki_port}"}
doc = yaml.safe_load(open(sys.argv[1]))
for ds in doc["datasources"]:
    if ds["uid"] in urls:
        ds["url"] = urls[ds["uid"]]
    ds.pop("correlations", None)
yaml.safe_dump({"apiVersion": 1, "datasources": doc["datasources"]}, sys.stdout, sort_keys=False)
PY
rm -f "$generated/datasources-prod.yaml"

# allowUiUpdates: the loop is edit-in-UI then export, so provisioned dashboards
# must stay saveable; Grafana re-reads a file only when its content changed.
cat > "$generated/provisioning/dashboards/dashboards.yaml" <<'YAML'
apiVersion: 1
providers:
  - name: repo
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
YAML

start_forward() {
  local name="$1" target="$2" local_port="$3" remote_port="$4"
  nohup kubectl -n observability port-forward --address 127.0.0.1 \
    "$target" "$local_port:$remote_port" >"$generated/forwards/$name.log" 2>&1 &
  echo $! > "$generated/forwards/$name.pid"
}

wait_for_port() {
  local port="$1" i
  for i in $(seq 1 40); do
    port_listening "$port" && return 0
    sleep 0.25
  done
  fail "port-forward on $port did not come up (see $generated/forwards/*.log)"
}

start_forward vm svc/vmsingle-victoria-metrics-single-server "$vm_port" 8428
start_forward loki svc/loki "$loki_port" 3100
wait_for_port "$vm_port"
wait_for_port "$loki_port"

# --network host so the container reaches the host-loopback forwards; anonymous Admin (loopback-only sandbox).
docker run -d --name "$container" --network host \
  -v "$generated/provisioning:/etc/grafana/provisioning:ro" \
  -v "$generated/dashboards:/var/lib/grafana/dashboards:ro" \
  -e GF_SERVER_HTTP_ADDR=127.0.0.1 \
  -e GF_SERVER_HTTP_PORT="$http_port" \
  -e GF_AUTH_ANONYMOUS_ENABLED=true \
  -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
  -e GF_AUTH_DISABLE_LOGIN_FORM=true \
  -e GF_ANALYTICS_REPORTING_ENABLED=false \
  -e GF_NEWS_NEWS_FEED_ENABLED=false \
  "$image" >/dev/null

for i in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$http_port/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$http_port/api/health" >/dev/null 2>&1 \
  || fail "Grafana did not become healthy (docker logs $container)"

echo
echo "sandbox up:  http://127.0.0.1:$http_port"
echo "image:       $image"
echo "datasources: victoriametrics -> 127.0.0.1:$vm_port, loki -> 127.0.0.1:$loki_port"
echo "dashboards:  $generated/dashboards"
echo "stop with:   $here/stop.sh"
