#!/usr/bin/env python3
"""check-tenants.py - keep the tenant list, tenant chart and OpenBao config in lockstep.

Validates argocd/tenants/tenants.json (complete, unique entries; members with an
explicit tailnet identity and optional GitHub login), the postStart TENANTS
marker in the OpenBao chart app (same logins, script passes `sh -n`), and the
per-tenant render of charts/tenant-access (RoleBinding, ClusterRoleBinding,
ServiceAccount, SecretStore; binding subjects == member identities).
"""

import json
import re
import shutil
import subprocess
import sys
import tempfile
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
IDENTITY = re.compile(r"^[A-Za-z0-9._@-]+$")
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


def parse_members(entry: dict, ref: str, errors: list) -> list:
    members = []
    raw = entry.get("members")
    if not isinstance(raw, list) or not raw:
        errors.append(f"{ref} needs a non-empty members list")
        return []
    for j, member in enumerate(raw):
        mref = f"{ref} member #{j + 1}"
        if not isinstance(member, dict):
            errors.append(f"{mref} is not an object")
            return []
        identity = str(member.get("identity") or "")
        user = str(member.get("user") or "")
        if not IDENTITY.match(identity):
            errors.append(f"{mref} has an invalid identity {identity!r}")
            return []
        if user and not GITHUB_USER.match(user):
            errors.append(f"{mref} has an invalid GitHub login {user!r}")
            return []
        if identity.endswith("@github") and user and identity != f"{user}@github":
            errors.append(f"{mref} identity {identity!r} does not match user {user!r}@github")
            return []
        members.append({"identity": identity, "user": user})
    if len({m["identity"] for m in members}) != len(members):
        errors.append(f"{ref} has duplicate member identities")
        return []
    return members


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
        ref = f"{rel}: entry #{i + 1}"
        if not isinstance(entry, dict):
            errors.append(f"{ref} is not an object")
            continue
        tenant = str(entry.get("tenant") or "")
        namespace = str(entry.get("namespace") or "")
        if not tenant or not namespace:
            errors.append(f"{ref} needs tenant and namespace")
            continue
        if not DNS_LABEL.match(tenant) or not DNS_LABEL.match(namespace):
            errors.append(f"{rel}: tenant/namespace {tenant!r}/{namespace!r} are not DNS labels")
            continue
        if tenant in RESERVED_TENANTS:
            errors.append(f"{rel}: tenant {tenant!r} collides with an existing OpenBao mount")
            continue
        members = parse_members(entry, ref, errors)
        if members:
            tenants.append({"tenant": tenant, "namespace": namespace, "members": members})

    for field in ("tenant", "namespace"):
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


def marker_triples(text: str, errors: list) -> set:
    match = MARKER.search(text)
    if not match:
        errors.append('postStart has no TENANTS="<tenant>:<namespace>[:<login>[|<login>]]" marker')
        return set()
    triples = set()
    for entry in match.group(1).split(","):
        parts = entry.strip().split(":")
        if len(parts) == 2:
            parts.append("")
        if len(parts) != 3 or not parts[0] or not parts[1]:
            errors.append(f"TENANTS entry {entry.strip()!r} is not <tenant>:<namespace>[:<login>[|<login>]]")
            continue
        tenant, namespace, logins = parts
        if not logins:
            triples.add((tenant, namespace, ""))
            continue
        for login in logins.split("|"):
            if not GITHUB_USER.match(login):
                errors.append(f"TENANTS login {login!r} is not a GitHub login")
                continue
            triples.add((tenant, namespace, login))
    return triples


def check_parity(tenants: list, triples: set, errors: list) -> None:
    want = set()
    for tenant in tenants:
        users = [m["user"] for m in tenant["members"] if m["user"]]
        if users:
            want |= {(tenant["tenant"], tenant["namespace"], user) for user in users}
        else:
            want.add((tenant["tenant"], tenant["namespace"], ""))
    for triple in sorted(want - triples):
        errors.append("TENANTS marker is missing " + ":".join(triple).rstrip(":"))
    for triple in sorted(triples - want):
        errors.append("TENANTS marker has no tenant-list member for " + ":".join(triple).rstrip(":"))


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
        identities = {m["identity"] for m in tenant["members"]}
        values = {
            "tenant": name,
            "namespace": namespace,
            "members": [
                {"identity": m["identity"], **({"user": m["user"]} if m["user"] else {})}
                for m in tenant["members"]
            ],
        }
        with tempfile.TemporaryDirectory(prefix="tenant-chart.") as tmp:
            values_file = Path(tmp) / "values.yaml"
            values_file.write_text(yaml.safe_dump(values))
            res = subprocess.run(
                ["helm", "template", str(TENANT_CHART), "--values", str(values_file)],
                capture_output=True,
                text=True,
                check=False,
            )
        if res.returncode != 0:
            errors.append(f"charts/tenant-access render failed for {name}:\n{res.stderr.strip()}")
            continue
        docs = [doc for doc in yaml.safe_load_all(res.stdout) if isinstance(doc, dict)]
        for doc in docs:
            if not doc.get("kind"):
                errors.append("charts/tenant-access renders a document without kind")
        rendered = {
            (doc.get("kind"), (doc.get("metadata") or {}).get("name"), (doc.get("metadata") or {}).get("namespace"))
            for doc in docs
            if doc.get("kind")
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
        for kind in ("RoleBinding", "ClusterRoleBinding"):
            subjects = {
                subject.get("name")
                for doc in docs
                if doc.get("kind") == kind
                for subject in (doc.get("subjects") or [])
            }
            if subjects != identities:
                errors.append(
                    f"{kind} subjects {sorted(subjects)} do not match members {sorted(identities)}"
                )


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
