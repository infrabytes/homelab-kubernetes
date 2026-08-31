#!/usr/bin/env python3
"""test-renovate.py — local Renovate dry-run.

Verifies that the Renovate configuration extracts the expected dependencies
and computes the expected updates, WITHOUT touching GitHub (no branches, no PRs).

Usage:
    .github/scripts/test-renovate.py    # run from anywhere; prints per-dependency results

Requirements:
    - gh CLI authenticated (any GitHub user) or GITHUB_TOKEN exported
    - network access (npm install + GitHub / helm / terraform registries)

What it does:
    1. copies the working tree (incl. uncommitted changes) into a temp dir
    2. installs the exact renovate version pinned in .pre-commit-config.yaml
       (never trusts the npx cache — stale cached versions are a known trap)
    3. runs renovate with platform=local in the temp copy (dryRun=lookup:
       extract + lookup, no writes — the local platform forces this)
    4. prints the extraction stats and, for every detected dependency, the
       detected current version and the proposed update (if any)
    5. fails when nothing was extracted (a config that silently matches
       nothing is a broken config)

Notes:
    - platform=local scans the current working directory, so the script
      chdir's into the temp copy — it is safe to invoke from anywhere
    - platform=local has no platform, so the GitHub token must be injected via
      RENOVATE_HOST_RULES; RENOVATE_TOKEN alone is not enough
    - the local platform forces dryRun to 'lookup' (values other than
      extract/lookup are unsupported and fall back to lookup), so Renovate
      never writes files here; the dry run verifies extraction and lookup
      only
    - renovate 44.x requires node ^24.11.0; the pre-commit node_env-lts node is
      tried first, then the system node
    - .terragrunt-cache, artifacts etc. are excluded (local tooling
      node_modules would otherwise be scanned as npm dependencies)
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NoReturn

CYAN = "\033[1;36m"
RED = "\033[1;31m"
RESET = "\033[0m"


def log(msg: str) -> None:
    print(f"{CYAN}[renovate-test]{RESET} {msg}")


def fail(msg: str) -> NoReturn:
    print(f"{RED}[renovate-test] ERROR: {msg}{RESET}", file=sys.stderr)
    sys.exit(1)


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, check=False, **kwargs)


def repo_root() -> Path:
    """Root of the enclosing git repository."""
    script_dir = Path(__file__).resolve().parent
    res = run(["git", "rev-parse", "--show-toplevel"], cwd=str(script_dir))
    if res.returncode != 0:
        fail(f"could not determine the git repository root: {res.stderr.strip()}")
    return Path(res.stdout.strip())


REPO_ROOT = repo_root()


def pinned_renovate_version() -> str:
    """Read the renovate rev pinned in .pre-commit-config.yaml."""
    config = (REPO_ROOT / ".pre-commit-config.yaml").read_text().splitlines()
    for i, line in enumerate(config):
        if "renovatebot/pre-commit-hooks" in line:
            for nxt in config[i + 1 : i + 5]:
                m = re.match(r"\s*rev:\s*(\S+)", nxt)
                if m:
                    return m.group(1)
    fail("could not read the renovate rev from .pre-commit-config.yaml")


def github_token() -> str:
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token and shutil.which("gh"):
        res = run(["gh", "auth", "token"])
        token = res.stdout.strip() if res.returncode == 0 else ""
    if not token:
        fail("no GitHub token: export GITHUB_TOKEN or run 'gh auth login'")
    return token


def node_candidates() -> list:
    candidates = []
    try:
        pre_nodes = sorted(
            (
                p
                for p in Path.home().glob(".cache/pre-commit/*/node_env-lts/bin/node")
                if p.is_file()
            ),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
    except OSError:
        pre_nodes = []
    for p in pre_nodes:
        try:
            if os.access(p, os.X_OK):
                candidates.append(str(p))
        except OSError:
            continue
    sys_node = shutil.which("node")
    if sys_node:
        candidates.append(sys_node)
    uniq = []
    for c in candidates:
        if c not in uniq:
            uniq.append(c)
    return uniq


def copy_working_tree(work_dir: Path) -> None:
    log("copying working tree (incl. uncommitted changes)")
    cmd = ["rsync", "-a"]
    for exclude in (
        ".git",
        ".terragrunt-cache",
        "artifacts",
        ".terraform",
    ):
        cmd += ["--exclude", exclude]
    cmd += [f"{REPO_ROOT}/", f"{work_dir}/"]
    res = run(cmd)
    if res.returncode != 0:
        fail(f"rsync failed:\n{res.stderr}")


def install_renovate(version: str, tools_dir: Path) -> Path:
    log(f"installing renovate@{version} (pinned in .pre-commit-config.yaml)")
    res = run(
        [
            "npm",
            "install",
            "--prefix",
            str(tools_dir),
            "--no-audit",
            "--no-fund",
            "--no-progress",
            f"renovate@{version}",
        ]
    )
    if res.returncode != 0:
        print(res.stderr, file=sys.stderr)
        fail(f"renovate@{version} install failed")
    binary = tools_dir / "node_modules" / "renovate" / "dist" / "renovate.js"
    if not binary.is_file():
        fail("renovate binary not found after install")
    return binary


def run_dry_run(
    node_bin: str, renovate_bin: Path, work_dir: Path, host_rules: str, cache_dir: Path
) -> subprocess.CompletedProcess:
    env = dict(
        os.environ,
        RENOVATE_PLATFORM="local",
        RENOVATE_HOST_RULES=host_rules,
        RENOVATE_ONBOARDING="false",
        RENOVATE_CACHE_DIR=str(cache_dir),
        RENOVATE_LOG_LEVEL="debug",
        # the local platform forces dryRun=lookup anyway; set it explicitly
        # so the config dump and docs stay in sync
        RENOVATE_DRY_RUN="lookup",
    )
    return run([node_bin, str(renovate_bin)], cwd=str(work_dir), env=env)


def extraction_stats(log_text: str):
    pattern = re.compile(r'"([a-z0-9-]+)": \{"fileCount": (\d+), "depCount": (\d+)\}')
    stats = {}
    for m in pattern.finditer(log_text):
        try:
            stats[m.group(1)] = (int(m.group(2)), int(m.group(3)))
        except (ValueError, IndexError):
            continue
    total = stats.get("total")
    return {k: v for k, v in stats.items() if k != "total"}, total


def parse_updates_section(log_text: str):
    """Parse the 'packageFiles with updates' config block from the log."""
    lines = log_text.splitlines()
    idx = next(
        (i for i, line in enumerate(lines) if "packageFiles with updates" in line),
        -1,
    )
    if idx < 0:
        return None
    start = next((i for i in range(idx, len(lines)) if '"config": {' in lines[i]), -1)
    if start < 0:
        return None
    depth = 0
    end = -1
    for i in range(start, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0:
            end = i
            break
    if end < 0:
        return None
    first = re.sub(r'^\s*"config":\s*', "", lines[start])
    block = "\n".join([first] + lines[start + 1 : end + 1])
    try:
        return json.loads(block)
    except json.JSONDecodeError:
        return None


def main() -> None:
    version = pinned_renovate_version()
    host_rules = json.dumps(
        [{"matchHost": "github.com", "hostType": "github", "token": github_token()}]
    )

    tmp_dir = Path(tempfile.mkdtemp(prefix="renovate-test.", dir="/tmp"))
    work_dir = tmp_dir / "repo"
    log_file = tmp_dir / "renovate.log"
    tools_dir = tmp_dir / "tools"
    keep = False
    try:
        work_dir.mkdir()
        copy_working_tree(work_dir)
        renovate_bin = install_renovate(version, tools_dir)

        chosen_node = None
        run_status = 1
        log_text = ""
        for cand in node_candidates():
            node_ver = run([cand, "--version"]).stdout.strip() or "unknown version"
            log(f"running with node: {cand} ({node_ver})")
            res = run_dry_run(
                cand, renovate_bin, work_dir, host_rules, tmp_dir / "cache"
            )
            run_status = res.returncode
            log_text = res.stdout + res.stderr
            log_file.write_text(log_text)
            if "Unsupported node environment" not in log_text:
                chosen_node = cand
                break
            log("node rejected by renovate's engine check, trying the next one")
        if chosen_node is None:
            engines = (
                json.loads(
                    (
                        tools_dir / "node_modules" / "renovate" / "package.json"
                    ).read_text()
                )
                .get("engines", {})
                .get("node", "?")
            )
            fail(
                f"no compatible node for renovate@{version} (engines: {engines}) "
                "— the pre-commit node_env-lts node works"
            )
        if run_status != 0:
            keep = True
            print("\n".join(log_text.splitlines()[-40:]), file=sys.stderr)
            fail(f"renovate dry-run failed (status {run_status})")

        print()
        node_version = run([chosen_node, "--version"]).stdout.strip()
        log(f"dry-run complete (renovate {version}, node {node_version})")
        print()

        log("extraction stats:")
        per_manager, total = extraction_stats(log_text)
        for name, (file_count, dep_count) in per_manager.items():
            print(f'  "{name}": {{"fileCount": {file_count}, "depCount": {dep_count}}}')
        if total:
            print(f'  "total": {{"fileCount": {total[0]}, "depCount": {total[1]}}}')
        print()

        log("pending updates:")
        for line in log_text.splitlines():
            if re.search(r"flattened updates found|Returning \d+ branch", line):
                print("  " + line.strip())
        print()

        log(
            "detected dependencies (manager | file | depName | currentValue | datasource | status):"
        )
        config = parse_updates_section(log_text)
        if config is None:
            keep = True
            fail("update section not found in log — extraction failed")
        total_deps = 0
        for manager, files in config.items():
            for f in files:
                for d in f.get("deps", []):
                    total_deps += 1
                    dep_name = d.get("depName") or d.get("depNameShort") or "<unknown>"
                    if d.get("skipReason"):
                        status = f"[skipped: {d['skipReason']}]"
                    else:
                        updates = d.get("updates") or []
                        if updates:
                            status = "-> " + ", ".join(
                                f"{u['newValue']} ({u['updateType']})" for u in updates
                            )
                        else:
                            status = "up to date"
                    print(
                        f"  {manager} | {f['packageFile']} | {dep_name} | "
                        f"{d.get('currentValue') or 'undefined'} | {d.get('datasource')} | {status}"
                    )
        if total_deps == 0:
            keep = True
            fail("no dependencies extracted — check the manager fileMatch patterns")
    finally:
        if keep:
            print(f"[renovate-test] workspace kept at: {tmp_dir} (log: {log_file})")
        else:
            shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
