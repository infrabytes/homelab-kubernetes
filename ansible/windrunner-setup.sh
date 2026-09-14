#!/bin/sh
# Idempotent windrunner setup for the proxmox-node-updates job; run as deschain
# (ssh ican 'bash -s' < ansible/windrunner-setup.sh); the final install/systemctl
# step needs sudo.
set -eu

REPO=~/homelab/homelab-kubernetes
VENV=~/.local/share/proxmox-maintenance/venv
BIN=~/.local/bin
SOPS_VERSION=3.11.0
ANSIBLE_CORE_VERSION=2.19.13

mkdir -p "$BIN"

if [ ! -x "$BIN/sops" ] || ! "$BIN/sops" --version | grep -q "$SOPS_VERSION"; then
  curl -fsSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" -o "$BIN/sops"
  chmod 700 "$BIN/sops"
fi

if [ ! -x "$VENV/bin/ansible-playbook" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "ansible-core==${ANSIBLE_CORE_VERSION}" proxmoxer kubernetes
fi
"$VENV/bin/ansible-galaxy" collection install -r "$REPO/ansible/requirements.yml" 2>/dev/null || true

KEYS=~/.config/sops/age/keys.txt
if [ ! -f "$KEYS" ]; then
  mkdir -p ~/.config/sops/age
  grep -oE 'SOPS_AGE_KEY=[^ ]+' ~/appdata/atlantis/atlantis.env | head -1 | cut -d= -f2- > "$KEYS"
  chmod 600 "$KEYS"
fi

for ip in 192.168.0.11 192.168.0.12 192.168.0.13 192.168.0.14; do
  ssh-keyscan -H "$ip" >> ~/.ssh/known_hosts 2>/dev/null || true
done
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts

CURRENT=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
if [ -n "$CURRENT" ] && ! echo "$CURRENT" | grep -q 'git@github.com:infrabytes/homelab-kubernetes.git'; then
  git -C "$REPO" remote set-url origin git@github.com:infrabytes/homelab-kubernetes.git
fi

install -m 644 "$REPO/ansible/systemd/proxmox-node-updates.service" /etc/systemd/system/
install -m 644 "$REPO/ansible/systemd/proxmox-node-updates.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now proxmox-node-updates.timer

systemctl list-timers proxmox-node-updates.timer --no-pager | head -3
systemd-analyze verify /etc/systemd/system/proxmox-node-updates.service /etc/systemd/system/proxmox-node-updates.timer && echo VERIFY-OK
