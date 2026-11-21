#!/usr/bin/env python3
"""check-tenants.py - validate the tenant list and its chart render.

Validates argocd/tenants/tenants.json (complete, unique entries; members with an
explicit tailnet identity and optional GitHub login) and the per-tenant render
of charts/tenant-access (RoleBinding, ClusterRoleBinding, ServiceAccount,
SecretStore; binding subjects == member identities). The OpenBao side (mounts,
policies, SSO roles) reads the same file directly via infra/openbao-config, so
there is no marker to compare against any more.
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
TENANT_CHART = ROOT / "charts" / "tenant-access"
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


def check_chart(tenants: list, errors: list) -> None:
    assert yaml is not None  # guarded by the caller; keeps Pyright quiet
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
    if yaml is None:
        log("WARN PyYAML not found, skipping the tenant chart render")
    elif tenants:
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
