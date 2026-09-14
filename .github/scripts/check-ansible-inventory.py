#!/usr/bin/env python3
"""check-ansible-inventory.py - keep ansible/inventory.yml and infra/env.hcl in lockstep.

Parses the `nodes = { ... }` block of infra/env.hcl and the `pve` group of
ansible/inventory.yml and asserts the IP ↔ inventory host ↔ pve_node ↔ vm_id ↔
Talos hostname tuples match both ways, so a node change in Terraform cannot
leave the patching playbook pointing at the wrong VM.
"""

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parents[2]
ENV_HCL = ROOT / "infra" / "env.hcl"
INVENTORY = ROOT / "ansible" / "inventory.yml"

NODE_BLOCK = re.compile(r"nodes\s*=\s*\{", re.MULTILINE)
NODE_ENTRY = re.compile(
    r'''"(?P<ip>\d+\.\d+\.\d+\.\d+)"\s*=\s*\{(?P<body>.*?)\n\s{6}\}''',
    re.MULTILINE | re.DOTALL,
)
FIELD = {
    "hostname": r'hostname\s*=\s*"([^"]+)"',
    "proxmox_node": r'proxmox_node\s*=\s*"([^"]+)"',
    "vm_id": r"vm_id\s*=\s*(\d+)",
}


def parse_env_hcl_nodes():
    text = ENV_HCL.read_text()
    start = NODE_BLOCK.search(text)
    if not start:
        sys.exit(f"{ENV_HCL}: no `nodes = {{` block found")
    depth = 0
    end = None
    for i in range(start.end() - 1, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    block = text[start.start() : end]
    nodes = {}
    for m in NODE_ENTRY.finditer(block):
        body = m.group("body")
        fields = {}
        for key, pattern in FIELD.items():
            fm = re.search(pattern, body)
            if not fm:
                sys.exit(f"{ENV_HCL}: node {m.group('ip')} is missing `{key}`")
            fields[key] = fm.group(1)
        nodes[m.group("ip")] = fields
    if not nodes:
        sys.exit(f"{ENV_HCL}: no node entries parsed from the nodes block")
    return nodes


def parse_inventory():
    if yaml is None:
        sys.exit("PyYAML is required for check-ansible-inventory (install python3-yaml)")
    data = yaml.safe_load(INVENTORY.read_text())
    hosts = (data.get("all", {}).get("children", {}).get("pve", {}) or {}).get("hosts", {})
    if not hosts:
        sys.exit(f"{INVENTORY}: no hosts under all.children.pve")
    parsed = {}
    for name, host in hosts.items():
        for key in ("ansible_host", "pve_node", "pve_vmid", "talos_node"):
            if key not in host:
                sys.exit(f"{INVENTORY}: host {name} is missing `{key}`")
        parsed[name] = {
            "ip": str(host["ansible_host"]),
            "hostname": host["talos_node"],
            "proxmox_node": host["pve_node"],
            "vm_id": str(host["pve_vmid"]),
        }
    return parsed


def main():
    env_nodes = parse_env_hcl_nodes()
    inv_hosts = parse_inventory()
    errors = []

    env_by_hostname = {v["hostname"]: (ip, v) for ip, v in env_nodes.items()}
    if len(env_by_hostname) != len(env_nodes):
        errors.append("infra/env.hcl: duplicate Talos hostnames in the nodes block")

    if set(inv_hosts) != {v["proxmox_node"] for v in env_nodes.values()}:
        errors.append(
            "inventory host set != env.hcl proxmox_node set: "
            f"inventory={sorted(inv_hosts)} env={sorted({v['proxmox_node'] for v in env_nodes.values()})}"
        )

    for name, host in sorted(inv_hosts.items()):
        match = env_by_hostname.get(host["hostname"])
        if match is None:
            errors.append(f"{name}: talos_node {host['hostname']} not in infra/env.hcl")
            continue
        ip, node = match
        if node["proxmox_node"] != name:
            errors.append(f"{name}: env.hcl maps {host['hostname']} to {node['proxmox_node']}")
        if node["vm_id"] != host["vm_id"]:
            errors.append(f"{name}: pve_vmid {host['vm_id']} != env.hcl vm_id {node['vm_id']}")

    if errors:
        print("ansible inventory drift detected:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    print(f"ansible inventory matches infra/env.hcl ({len(inv_hosts)} hosts)")


if __name__ == "__main__":
    main()
