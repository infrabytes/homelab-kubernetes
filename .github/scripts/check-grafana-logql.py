#!/usr/bin/env python3
"""check-grafana-logql.py - execute every dashboard LogQL query against Loki.

Reads the GrafanaDashboard ConfigMaps under platform/grafana-dashboards/,
extracts each Loki-backed panel target and template-variable query, substitutes
Grafana's variables with match-everything stand-ins, and runs them against
Loki (LOKI_URL if set, else the in-cluster service, else localhost:3100).

A query that errors or returns success with no data fails the check: a stream
selector over structured metadata (`pod`, `detected_level`) matches zero
streams without an error and renders a permanently blank panel. Queries whose
data is legitimately sparse get a longer lookback from
logql-lookback-allowlist.yaml; an empty result still fails.

Usage: check-grafana-logql.py <dashboard.yaml>...
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

ALLOWLIST_PATH = Path(__file__).with_name("logql-lookback-allowlist.yaml")
CLUSTER_URL = "http://loki.observability.svc.cluster.local:3100"
LOCAL_URL = "http://localhost:3100"
ALL_VALUE = ".+"
INTERVAL = "1m"
LOG_LOOKBACK_SECONDS = 3600
DISCOVERY_TIMEOUT = 3
QUERY_TIMEOUT = 5
VARIABLE_RE = re.compile(r"\$\{?(\w+)\}?")


def log(msg):
    print(f"[check-grafana-logql] {msg}")


def http_json(url, params=None, timeout=QUERY_TIMEOUT):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def http_reachable(url, timeout=DISCOVERY_TIMEOUT):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.status == 200


def loki_base():
    explicit = os.environ.get("LOKI_URL")
    for base in ([explicit] if explicit else [CLUSTER_URL, LOCAL_URL]):
        try:
            if http_reachable(f"{base}/ready"):
                return base
        except (urllib.error.URLError, OSError, ValueError, TimeoutError):
            continue
    return None


def load_allowlist():
    if not ALLOWLIST_PATH.is_file():
        return {}
    try:
        data = yaml.safe_load(ALLOWLIST_PATH.read_text()) or {}
    except yaml.YAMLError as exc:
        log(f"ignoring unparsable {ALLOWLIST_PATH.name}: {exc}")
        return {}
    return {(e.get("dashboard"), e.get("panel")): e.get("interval", INTERVAL) for e in data.get("allow", [])}


def dashboards_in(path):
    try:
        docs = list(yaml.safe_load_all(path.read_text()))
    except yaml.YAMLError as exc:
        log(f"{path}: unparsable YAML: {exc}")
        return []
    found = []
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
            continue
        for key, text in (doc.get("data") or {}).items():
            if not (isinstance(text, str) and key.endswith(".json")):
                continue
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError as exc:
                log(f"{path}: data.{key} is not valid JSON: {exc}")
                continue
            if isinstance(parsed, dict) and "panels" in parsed:
                found.append(parsed)
    return found


def is_loki(datasource):
    return isinstance(datasource, dict) and datasource.get("type") == "loki"


def substitute(expr, interval):
    values = {
        "namespace": ALL_VALUE,
        "container": ALL_VALUE,
        "stream": ALL_VALUE,
        "pod": ".*",
        "query": "",
        "__interval": interval,
        "__rate_interval": interval,
        "__interval_ms": str(int(re.sub(r"\D", "", interval) or 60) * 1000),
    }

    def replace(match):
        name = match.group(1)
        return values.get(name, match.group(0))

    return VARIABLE_RE.sub(replace, expr)


def panel_queries(dashboard, allowlist):
    uid = dashboard.get("uid")
    for panel in dashboard.get("panels", []):
        targets = panel.get("targets") or []
        interval = allowlist.get((uid, panel.get("title")), INTERVAL)
        for target in targets:
            expr = target.get("expr")
            if not expr or not (is_loki(target.get("datasource")) or is_loki(panel.get("datasource"))):
                continue
            yield panel.get("title") or target.get("refId") or "unnamed panel", panel.get("type"), substitute(expr, interval)


def variable_queries(dashboard):
    for var in (dashboard.get("templating") or {}).get("list", []):
        query = var.get("query")
        if not isinstance(query, dict) or not is_loki(var.get("datasource")):
            continue
        if query.get("type") == 1 and query.get("label"):
            yield var.get("name"), query["label"], query.get("stream") or ""
            continue
        legacy = query.get("query", "")
        match = re.match(r"label_values\(\s*(?:([^,)]+),)?\s*([\w.]+)\s*\)$", legacy)
        if match:
            yield var.get("name"), match.group(2), match.group(1) or ""


def run_metric(base, expr):
    result = http_json(f"{base}/loki/api/v1/query", {"query": expr})
    if result.get("status") != "success":
        raise RuntimeError(result.get("error") or json.dumps(result)[:200])
    return len(result["data"]["result"])


def run_logs(base, expr):
    now = int(time.time())
    result = http_json(
        f"{base}/loki/api/v1/query_range",
        {"query": expr, "start": now - LOG_LOOKBACK_SECONDS, "end": now, "limit": 5},
    )
    if result.get("status") != "success":
        raise RuntimeError(result.get("error") or json.dumps(result)[:200])
    return sum(len(stream.get("values", [])) for stream in result["data"]["result"])


def run_label(base, label, selector):
    params = {"query": selector} if selector else None
    result = http_json(f"{base}/loki/api/v1/label/{urllib.parse.quote(label)}/values", params)
    if result.get("status") != "success":
        raise RuntimeError(result.get("error") or json.dumps(result)[:200])
    return len(result["data"])


def unstubbed(expr):
    return sorted({m.group(1) for m in VARIABLE_RE.finditer(expr) if not m.group(1).startswith("__")})


def main():
    if yaml is None:
        log("PyYAML not found, skipping (pip install pyyaml to validate LogQL)")
        return 0
    paths = [Path(p) for p in sys.argv[1:]]
    if not paths:
        log("no dashboard files given, skipping")
        return 0
    allowlist = load_allowlist()
    dashboards = [(path, dash) for path in paths for dash in dashboards_in(path)]
    if not dashboards:
        log(f"no Loki dashboard ConfigMaps in {len(paths)} file(s), skipping")
        return 0
    base = loki_base()
    if base is None:
        log("Loki unreachable (LOKI_URL / cluster service / localhost:3100), skipping")
        return 0
    log(f"Loki at {base}")
    failures = 0
    checked = 0
    for path, dashboard in dashboards:
        log(f"{path}: {dashboard.get('title') or dashboard.get('uid')}")
        for title, panel_type, expr in panel_queries(dashboard, allowlist):
            checked += 1
            unknown = unstubbed(expr)
            if unknown:
                failures += 1
                log(f"  FAIL {title}: unsubstituted variable(s) {', '.join(unknown)}: {expr}")
                continue
            try:
                rows = run_logs(base, expr) if panel_type == "logs" else run_metric(base, expr)
            except (RuntimeError, urllib.error.URLError, OSError, ValueError, TimeoutError) as exc:
                failures += 1
                log(f"  FAIL {title}: {exc}: {expr}")
                continue
            if rows == 0:
                failures += 1
                log(f"  FAIL {title}: query succeeded but returned no data: {expr}")
            else:
                log(f"  ok   {title}: {rows} result(s)")
        for name, label, selector in variable_queries(dashboard):
            checked += 1
            selector = substitute(selector, INTERVAL) if selector else ""
            try:
                values = run_label(base, label, selector)
            except (RuntimeError, urllib.error.URLError, OSError, ValueError, TimeoutError) as exc:
                failures += 1
                log(f"  FAIL variable ${name}: {exc}")
                continue
            if values == 0:
                failures += 1
                log(f"  FAIL variable ${name}: label {label!r} has no values")
            else:
                log(f"  ok   variable ${name}: {values} value(s)")
    log(f"{checked} query/queries checked, {failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
