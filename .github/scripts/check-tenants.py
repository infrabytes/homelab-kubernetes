#!/usr/bin/env python3
"""check-tenants.py - keep the tenant list, tenant chart and OpenBao config in lockstep.

Validates argocd/tenants/tenants.json (complete, unique, <user>@github entries),
the postStart TENANTS marker in the OpenBao chart app (same tenant/namespace/user
triples, script passes `sh -n`), and the per-tenant render of charts/tenant-access
(RoleBinding, ClusterRoleBinding, ServiceAccount, SecretStore).
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[2]
TENANTS_FILE = ROOT / "argocd" / "tenants" / "tenants.json"
OPENBAO_APP = ROOT / "platform" / "helm-charts" / "openbao" / "application.yaml"
TENANT_CHART = ROOT / "charts" / "tenant-access"
MARKER = re.compile(r'^[ \t]*TENANTS="([^"]*)"[ \t]*$', re.MULTILINE)
DNS_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
GITHUB_USER = re.compile(r"^[A-Za-z0-9-]+$")
# Mount paths this cluster already uses; a tenant mount there would inherit their policies.
RESERVED_TENANTS = {
    "secret",
    "sys",
    "auth",
    "identity",
    "cubbyhole",
    "kubernetes",
    "oidc",
    "oidc-tailnet",
}


def log(msg: str) -> None:
    print(f"[check-tenants] {msg}")


def load_tenants(errors: list) -> list:
    rel = TENANTS_FILE.relative_to(ROOT)
    try:
        data = json.loads(TENANTS_FILE.read_text())
    except FileNotFoundError:
        errors.append(f"{rel} is missing")
        return []
    except json.JSONDecodeError as err:
        errors.append(f"{rel}: {err}")
        return []
    if not isinstance(data, list):
        errors.append(f"{rel} must be a JSON array")
        return []

    tenants = []
    for i, entry in enumerate(data):
        if not isinstance(entry, dict):
            errors.append(f"{rel}: entry #{i + 1} is not an object")
            continue
        fields = {k: str(entry.get(k) or "") for k in ("tenant", "namespace", "identity", "user")}
        if not all(fields.values()):
            errors.append(f"{rel}: entry #{i + 1} has an empty tenant/namespace/identity/user")
            continue
        if not DNS_LABEL.match(fields["tenant"]) or not DNS_LABEL.match(fields["namespace"]):
            errors.append(f"{rel}: tenant/namespace {fields['tenant']!r}/{fields['namespace']!r} are not DNS labels")
            continue
        if not GITHUB_USER.match(fields["user"]):
            errors.append(f"{rel}: {fields['tenant']} user {fields['user']!r} is not a GitHub login")
            continue
        if fields["tenant"] in RESERVED_TENANTS:
            errors.append(f"{rel}: tenant {fields['tenant']!r} collides with an existing OpenBao mount")
            continue
        if fields["identity"] != f"{fields['user']}@github":
            errors.append(f"{rel}: {fields['tenant']} identity {fields['identity']!r} is not <user>@github")
            continue
        tenants.append(fields)

    for field in ("tenant", "namespace", "identity"):
        seen = set()
        for tenant in tenants:
            if tenant[field] in seen:
                errors.append(f"{rel}: duplicate {field} {tenant[field]!r}")
            seen.add(tenant[field])
    return tenants


def openbao_text(errors: list) -> str:
    rel = OPENBAO_APP.relative_to(ROOT)
    try:
        return OPENBAO_APP.read_text()
    except OSError as err:
        errors.append(f"{rel}: cannot read: {err}")
        return ""


def poststart_script(raw: str, errors: list) -> str:
    rel = OPENBAO_APP.relative_to(ROOT)
    try:
        app = yaml.safe_load(raw)
        values = yaml.safe_load(app["spec"]["source"]["helm"]["values"])
        command = values["server"]["postStart"]
        return command[command.index("-c") + 1]
    except Exception as err:  # noqa: BLE001
        errors.append(f"{rel}: cannot read the postStart script: {err}")
        return ""


def marker_triples(script: str, errors: list) -> set:
    match = MARKER.search(script)
    if not match:
        errors.append('postStart has no TENANTS="<tenant>:<namespace>:<login>[,<...>]" marker')
        return set()
    triples = set()
    for entry in match.group(1).split(","):
        parts = tuple(entry.strip().split(":"))
        if len(parts) != 3 or not all(parts):
            errors.append(f"TENANTS entry {entry.strip()!r} is not <tenant>:<namespace>:<login>")
            continue
        triples.add(parts)
    return triples


def check_parity(tenants: list, triples: set, errors: list) -> None:
    want = {(t["tenant"], t["namespace"], t["user"]) for t in tenants}
    for triple in sorted(want - triples):
        errors.append("TENANTS marker is missing " + ":".join(triple))
    for triple in sorted(triples - want):
        errors.append("TENANTS marker has no tenant-list entry for " + ":".join(triple))


def check_shell(script: str, errors: list) -> None:
    if not shutil.which("sh"):
        log("WARN sh not found, skipping the postStart syntax check")
        return
    res = subprocess.run(["sh", "-n"], input=script, text=True, capture_output=True, check=False)
    if res.returncode != 0:
        errors.append(f"postStart script fails sh -n:\n{res.stderr.strip()}")


def check_chart(tenants: list, errors: list) -> None:
    if not shutil.which("helm"):
        log("WARN helm not found, skipping the tenant chart render")
        return
    for tenant in tenants:
        name, namespace = tenant["tenant"], tenant["namespace"]
        args = ["helm", "template", str(TENANT_CHART)]
        for key in ("tenant", "namespace", "identity"):
            args += ["--set", f"{key}={tenant[key]}"]
        res = subprocess.run(args, capture_output=True, text=True, check=False)
        if res.returncode != 0:
            errors.append(f"charts/tenant-access render failed for {name}:\n{res.stderr.strip()}")
            continue
        rendered = {
            (doc.get("kind"), (doc.get("metadata") or {}).get("name"), (doc.get("metadata") or {}).get("namespace"))
            for doc in yaml.safe_load_all(res.stdout)
            if isinstance(doc, dict) and doc.get("kind")
        }
        expected = {
            ("RoleBinding", "tenant-admin", namespace),
            ("ClusterRoleBinding", f"tenant-{name}-view", None),
            ("ServiceAccount", f"{name}-eso", namespace),
            ("SecretStore", f"openbao-{name}", namespace),
        }
        for obj in sorted(expected - rendered):
            errors.append(f"charts/tenant-access does not render {obj[0]} {obj[1]}")
        for obj in sorted(rendered - expected):
            errors.append(f"charts/tenant-access renders unexpected {obj[0]} {obj[1]}")


def main() -> int:
    errors: list = []
    tenants = load_tenants(errors)
    raw = openbao_text(errors)
    if raw:
        check_parity(tenants, marker_triples(raw, errors), errors)
        if yaml is None:
            log("WARN PyYAML not found, skipping the postStart syntax check and the chart render")
        elif script := poststart_script(raw, errors):
            check_shell(script, errors)
    if tenants and yaml is not None:
        check_chart(tenants, errors)

    for error in errors:
        log(f"FAIL {error}")
    if errors:
        log(f"{len(errors)} problem(s) found")
        return 1
    log(f"OK {len(tenants)} tenant(s) in sync with the OpenBao config")
    return 0


if __name__ == "__main__":
    sys.exit(main())
