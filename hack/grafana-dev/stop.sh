#!/usr/bin/env bash
# Stops the sandbox container and only the port-forwards it started (pidfiles in generated/; foreign forwards are never touched).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
generated="$here/generated"
container="${GRAFANA_DEV_CONTAINER:-grafana-dev-sandbox}"

stopped=0

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
  docker rm -f "$container" >/dev/null
  echo "removed container $container"
  stopped=1
fi

for pidfile in "$generated"/forwards/*.pid; do
  [[ -e "$pidfile" ]] || continue
  pid="$(cat "$pidfile")"
  name="$(basename "$pidfile" .pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null \
      && grep -q port-forward "/proc/$pid/cmdline" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "stopped $name port-forward (pid $pid)"
    stopped=1
  else
    echo "$name port-forward (pid $pid) is gone; dropping stale pidfile"
  fi
  rm -f "$pidfile"
done

[[ $stopped -eq 1 ]] || echo "nothing to stop"
