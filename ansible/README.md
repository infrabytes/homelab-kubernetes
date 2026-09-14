# Proxmox node maintenance

Rolling, drain-aware patching of the four PVE hosts (`proxmox01`–`proxmox04`)
that host the Talos cluster. One Ansible playbook, one host at a time, reboots
only when required.

This supersedes the legacy `~/homelab/ansible/patching.yml` (single host
`.21`, VMs 100/1001); that playbook and its plaintext `root@pam` token in
`~/homelab/ansible/vars/patching_vars.yml` are out of scope here and should
be retired separately.

## What a run does

1. **Preflight** (once per host, before anything changes): secrets present in
   the environment, PVE quorate, all four Talos nodes `Ready`, every Longhorn
   volume healthy. Any failure aborts before the host is touched.
2. **Patch**: installs `update-notifier-common` + `needrestart` (first run
   only), `apt update` + `full-upgrade` + `autoremove --purge`, then verifies
   zero pending upgrades remain.
3. **Reboot decision**: reboot only when the newest installed kernel differs
   from the running one, `/var/run/reboot-required` exists, or a
   reboot-relevant package (`proxmox-kernel`, `pve-manager`, `qemu-server`,
   `zfsutils-linux`, `libc6`, `systemd`) changed. Otherwise the host stays up.
4. **Maintenance window** (only on reboot): workers (`proxmox02`–`04`) cordon
   + drain their Talos node (PDBs respected, DaemonSets ignored), then the VM
   is stopped gracefully via the guest agent (`qm shutdown` semantics — never
   a hard stop), the host reboots, the VM starts, the node is waited to
   `Ready`, uncordoned, and all Longhorn volumes must be healthy again before
   the next host. `proxmox01` (single control plane `talos-cp-1`) is never
   cordoned or drained — graceful VM shutdown only. Expect ~2–5 min without
   the Kubernetes API during its reboot.
5. **Report**: one JSON log line per host plus a run summary to Grafana Cloud
   Loki (`job="proxmox-node-updates"`). Alert rules live in
   `infra/grafana-cloud-config/maintenance_alerts.tf` (failed run + 8-day
   dead-man).

Roll order is the inventory order: `proxmox02 → proxmox03 → proxmox04 →
proxmox01` (`serial: 1`, `any_errors_fatal`). Any failed step aborts the
remaining hosts, leaves the current node cordoned, and exits non-zero naming
the host and step.

## Commands

Secrets come from the environment, never disk — wrap every run:

```sh
cd ansible
sops exec-env ../infra/secrets.sops.yaml \
  'ansible-playbook -i inventory.yml proxmox-node-updates.yml --check --diff'
```

- **Dry run** (`--check --diff`): nothing is installed, cordoned, stopped or
  rebooted; VM/reboot tasks print what they would do.
- **Canary a single host** (needs an explicit go-ahead — it performs a real
  roll of that host):

  ```sh
  sops exec-env ../infra/secrets.sops.yaml \
    'ansible-playbook -i inventory.yml proxmox-node-updates.yml --limit proxmox02'
  ```

  The preflight still gates on the whole cluster (all nodes Ready, all
  volumes healthy), so it aborts on an unhealthy night.
- **Full run**: same without `--limit`. Normally driven by the windrunner
  timer, not by hand.

## Recovery: a host fails to return

If a worker's node stays `NotReady` or the Longhorn gate times out, the roll
aborts and the node stays cordoned:

1. Check the host over SSH (`ssh root@192.168.0.1X`) and the VM in the PVE
   UI; start the VM by hand if the playbook died between stop and start.
2. Wait for the Talos node to go `Ready`, then uncordon:
   `kubectl uncordon talos-worker-N`.
3. Re-run the playbook — hosts with zero pending upgrades and no reboot
   marker are no-ops, so it resumes with the first unfinished host.

If `proxmox01` fails to return, the whole cluster is down until it does:
console into the VM from the PVE UI, then continue as above.

## windrunner setup

`windrunner-setup.sh` (run as the `deschain` user; the final
`install`/`systemctl` step needs sudo) installs the pinned `sops` binary, a
venv with `ansible-core` + `proxmoxer` + `kubernetes` + the collections, the
age key, known_hosts entries, and the system units:

- `proxmox-node-updates.service`: `flock -n` lock +
  `sops exec-env ... ansible-playbook`, `ExecStartPre` pulls the repo.
- `proxmox-node-updates.timer`: `OnCalendar=Sun *-*-* 04:00:00`
  (Europe/Vienna), `Persistent=true` (catch-up at the next boot).

Never `systemctl start proxmox-node-updates` as a test — that performs a
real roll. Use the dry run above instead.

## Requirements

- ansible-core with the collections pinned in `requirements.yml`
  (`community.proxmox`, `kubernetes.core`) plus `proxmoxer` and
  `kubernetes` Python packages.
- Root SSH to the four PVE hosts and an admin kubeconfig at
  `infra/cluster/artifacts/kubeconfig`.
- `sops` + the age key for `infra/secrets.sops.yaml`.
