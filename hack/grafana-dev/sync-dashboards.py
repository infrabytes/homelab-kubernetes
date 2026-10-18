#!/usr/bin/env python3
"""Extract ConfigMap-backed GrafanaDashboard JSON into generated/dashboards/."""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_KUBECONFIG = (
    Path(__file__).resolve().parents[2] / "infra" / "cluster" / "artifacts" / "kubeconfig"
)


class KubectlError(RuntimeError):
    pass


def kubectl_json(kubeconfig, *args):
    proc = subprocess.run(
        ["kubectl", "--kubeconfig", str(kubeconfig), *args, "-o", "json"],
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise KubectlError(proc.stderr.strip() or f"kubectl {' '.join(args)} failed")
    return json.loads(proc.stdout)


def find_configmap(kubeconfig, namespace, name):
    try:
        return kubectl_json(kubeconfig, "-n", namespace, "get", "configmap", name)
    except KubectlError:
        pass
    items = kubectl_json(
        kubeconfig,
        "get",
        "configmaps",
        "-A",
        "--field-selector",
        f"metadata.name={name}",
    ).get("items", [])
    if len(items) == 1:
        return items[0]
    if not items:
        raise KubectlError(f"configmap {name} not found in any namespace")
    raise KubectlError(f"configmap {name} is ambiguous: found in {len(items)} namespaces")


def remote_source(spec):
    for source in ("url", "grafanaCom", "oci"):
        if spec.get(source):
            return source
    return "unknown source"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--kubeconfig",
        default=str(DEFAULT_KUBECONFIG),
        help="admin kubeconfig (default: infra/cluster/artifacts/kubeconfig)",
    )
    parser.add_argument(
        "--out",
        default=str(Path(__file__).resolve().parent / "generated" / "dashboards"),
        help="output directory; wiped first",
    )
    args = parser.parse_args()

    out = Path(args.out).resolve()
    if "generated" not in out.parts:
        sys.exit(f"refusing to wipe {out}: not under a generated/ directory")

    dashboards = kubectl_json(args.kubeconfig, "get", "grafanadashboards", "-A").get(
        "items", []
    )

    if out.exists():
        shutil.rmtree(out)

    synced = []
    skipped = []
    for cr in dashboards:
        name = cr["metadata"]["name"]
        namespace = cr["metadata"]["namespace"]
        spec = cr.get("spec") or {}
        ref = spec.get("configMapRef")
        if not ref:
            skipped.append(f"{namespace}/{name} ({remote_source(spec)})")
            continue
        try:
            configmap = find_configmap(args.kubeconfig, namespace, ref["name"])
        except KubectlError as exc:
            sys.exit(f"{namespace}/{name}: {exc}")
        payload = (configmap.get("data") or {}).get(ref["key"])
        if payload is None:
            sys.exit(
                f"{namespace}/{name}: key {ref['key']} missing from configmap {ref['name']}"
            )
        json.loads(payload)
        dest = out / (spec.get("folder") or "") / f"{name}.json"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(payload)
        synced.append(f"{spec.get('folder') or '-'}/{name}.json")

    for entry in sorted(synced):
        print(f"synced  {entry}")
    for entry in sorted(skipped):
        print(f"skipped {entry}")
    print(f"{len(synced)} dashboard(s) synced to {out}, {len(skipped)} skipped")


if __name__ == "__main__":
    main()
