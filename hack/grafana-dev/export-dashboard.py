#!/usr/bin/env python3
"""Write a sandbox dashboard back into its ConfigMap and flip the resyncPeriod."""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

import yaml

DEFAULT_URL = os.environ.get("GRAFANA_DEV_URL", "http://127.0.0.1:33000")


def mapping(node):
    if node is None or not node.tag.endswith(":map"):
        return None
    return {key.value: value for key, value in node.value}


def find_export_target(text, uid):
    for doc in yaml.compose_all(text):
        top = mapping(doc)
        if not top or top.get("kind") is None:
            continue
        if top["kind"].value != "ConfigMap":
            continue
        for key, value in (mapping(top["data"]) or {}).items():
            try:
                dashboard = json.loads(value.value)
            except (AttributeError, json.JSONDecodeError):
                continue
            if isinstance(dashboard, dict) and dashboard.get("uid") == uid:
                return {
                    "key": key,
                    "value": value,
                    "configmap": mapping(top["metadata"])["name"].value,
                }
    return None


def find_resync_node(text, configmap, key):
    for doc in yaml.compose_all(text):
        top = mapping(doc)
        if not top or top.get("kind") is None:
            continue
        if top["kind"].value != "GrafanaDashboard":
            continue
        spec = mapping(top.get("spec")) or {}
        ref = mapping(spec.get("configMapRef")) or {}
        name = ref.get("name")
        ref_key = ref.get("key")
        if name and ref_key and name.value == configmap and ref_key.value == key:
            return spec["resyncPeriod"]
    return None


def fetch_dashboard(base_url, uid):
    url = f"{base_url}/api/dashboards/uid/{uid}"
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        sys.exit(f"GET {url} -> HTTP {exc.code}; is that dashboard in the sandbox?")
    except urllib.error.URLError as exc:
        sys.exit(f"GET {url} failed ({exc.reason}); is ./run.sh up?")


def splice_json_block(text, value_node, payload):
    lines = text.splitlines(keepends=True)
    start = value_node.start_mark.line
    end = value_node.end_mark.line
    header = lines[start].rstrip("\n")
    if start == end or not header.endswith(("|", "|-", "|+", ">", ">-", ">+")):
        sys.exit("the ConfigMap value is not a block scalar; refusing to rewrite it")
    indent = lines[start + 1][: len(lines[start + 1]) - len(lines[start + 1].lstrip())]
    body = [indent + line + "\n" for line in payload.splitlines()]
    return "".join(lines[: start + 1] + body + lines[end:])


def flip_resync(text, resync_node):
    lines = text.splitlines(keepends=True)
    old = resync_node.value
    new = "59m" if old == "1h" else "1h"
    line = lines[resync_node.start_mark.line]
    column = resync_node.start_mark.column
    lines[resync_node.start_mark.line] = line[:column] + new + line[column + len(old) :]
    return "".join(lines), old, new


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("uid")
    parser.add_argument("yaml_file", type=Path)
    parser.add_argument("--url", default=DEFAULT_URL)
    args = parser.parse_args()

    text = args.yaml_file.read_text()
    target = find_export_target(text, args.uid)
    if target is None:
        sys.exit(
            f"{args.yaml_file}: no ConfigMap carries a dashboard with uid {args.uid!r} "
            "(only ConfigMap-backed dashboards are exportable)"
        )

    dashboard = fetch_dashboard(args.url, args.uid)["dashboard"]
    dashboard.pop("id", None)
    payload = json.dumps(dashboard, indent=2, ensure_ascii=False)

    updated = splice_json_block(text, target["value"], payload)
    resync_node = find_resync_node(updated, target["configmap"], target["key"])
    if resync_node is None:
        sys.exit("internal error: no GrafanaDashboard references the edited ConfigMap")
    updated, old_period, new_period = flip_resync(updated, resync_node)

    round_trip = find_export_target(updated, args.uid)
    if round_trip is None or json.loads(round_trip["value"].value) != dashboard:
        sys.exit("internal error: the rewritten file does not round-trip")

    args.yaml_file.write_text(updated)
    print(f"exported {dashboard.get('title', args.uid)!r} (uid {args.uid}) -> {args.yaml_file}")
    print(
        f"  configmap {target['configmap']}/{target['key']}, "
        f"resyncPeriod {old_period} -> {new_period}"
    )
    print(f"  review with: git diff {args.yaml_file}")


if __name__ == "__main__":
    main()
