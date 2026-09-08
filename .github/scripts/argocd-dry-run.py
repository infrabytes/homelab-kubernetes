#!/usr/bin/env python3
"""argocd-dry-run.py - validate changed ArgoCD apps with host dry-run syncs.

The PR validation workflow checks out the base (main) and target
(refs/pull/N/merge) branches and runs this script, which:

1. computes the changed files and maps them to app directories
   (platform/<app>, platform/helm-charts/<app> or apps/<app>)
2. creates one temporary ArgoCD Application per changed app
   (dryrun-pr-<N>-<app>, targetRevision refs/pull/N/merge) on the HOST
   ArgoCD, in a dry-run envelope: no automated sync, no resources
   finalizer, syncOptions preserved. Helm-chart apps are mirrored from
   their committed Application manifest (chart + targetRevision + values
   stay verbatim from the PR branch); directory apps get a generated
   manifest with the same shape as the ApplicationSet template
3. runs `argocd app sync --dry-run` and polls the operation to a terminal
   phase. The create skips ArgoCD's spec validation (--validate=false: its
   repo connectivity test is broken for ghcr.io OCI repos), so render
   errors surface in the sync as a ComparisonError and missing CRDs in the
   sync result ("<Kind>.<group> not found")
4. supplements the dry-run with a namespace check: every namespace the
   app targets must exist on the host or be created by the app (the
   dry-run itself does not catch a missing destination namespace)
5. deletes the temp app (--cascade=false; without the resources finalizer
   the delete is instant and applies nothing)
6. writes a markdown report and exits non-zero if any app failed (the
   workflow still posts the comment)

Everything talks to ArgoCD through the argocd CLI authenticated with the
preview-bot API token, which the script reads from the preview-bot-auth
Secret (namespace arc-runners) via the runner pod's service account. The
only third-party dependency is PyYAML for mirroring chart Applications.

Usage:
    argocd-dry-run.py --repo-url <url> --pr <number>
        --base-dir <dir> --target-dir <dir>
        [--argocd-server <url>] [--token-secret <ns/name:key>]
        [--output <path>]
    argocd-dry-run.py --cleanup --pr <number>
        [--argocd-server <url>] [--token-secret <ns/name:key>]
"""

import argparse
import base64
import json
import os
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

APP_LABEL_KEY = "preview.homelab/pr"
DESTINATION_SERVER = "https://kubernetes.default.svc"
REVISION_PREFIX = "refs/pull"
TERMINAL_PHASES = ("Succeeded", "Failed", "Error", "Terminating")
SA_BASE = Path("/var/run/secrets/kubernetes.io/serviceaccount")


def log(msg: str) -> None:
    print(f"[argocd-dry-run] {msg}")


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, check=False, **kwargs)


def git_run(target_dir: Path, args: list[str]) -> str:
    res = run(["git", "-C", str(target_dir), *args])
    if res.returncode != 0:
        raise RuntimeError(f"git {args[0]} failed:\n{res.stderr.strip()}")
    return res.stdout.strip()


def changed_files(base_dir: Path, target_dir: Path) -> list[str]:
    """Files changed between the base and target checkouts."""
    base_sha = git_run(base_dir, ["rev-parse", "HEAD"])
    target_sha = git_run(target_dir, ["rev-parse", "HEAD"])
    try:
        out = git_run(target_dir, ["diff", "--name-only", base_sha, target_sha])
    except RuntimeError:
        # base SHA not in the target checkout's object store (main moved): fall back to its own refs.
        out = git_run(target_dir, ["diff", "--name-only", "origin/main...HEAD"])
    return [f for f in out.splitlines() if f]


def app_for_path(path: str) -> str | None:
    """Map a changed file to its app directory (platform/x, apps/x)."""
    parts = path.split("/")
    if len(parts) >= 2 and parts[0] in ("platform", "apps") and parts[1]:
        if (
            parts[0] == "platform"
            and parts[1] == "helm-charts"
            and len(parts) >= 3
            and parts[2]
        ):
            return f"platform/helm-charts/{parts[2]}"
        return f"{parts[0]}/{parts[1]}"
    return None


def app_name(app: str, pr: int) -> str:
    """DNS-safe Application name for a dry-run deployment."""
    basename = app.rsplit("/", 1)[-1].lower()
    sanitized = "".join(c if c.isalnum() or c == "-" else "-" for c in basename)
    return f"dryrun-pr-{pr}-{sanitized}"


def application_manifest(name: str, repo_url: str, path: str, revision: str, pr: int) -> str:
    """Render the ArgoCD Application CR for a dry-run of a directory app.

    Same shape as the ApplicationSet template (no destination namespace,
    no syncPolicy): the dry-run must match what the real sync would do.
    """
    return f"""apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {name}
  namespace: argocd
  labels:
    {APP_LABEL_KEY}: "{pr}"
spec:
  project: default
  source:
    repoURL: {repo_url}
    targetRevision: {revision}
    path: {path}
    directory:
      recurse: true
  destination:
    server: {DESTINATION_SERVER}
"""


def chart_label(doc: dict) -> str:
    """Human label of the under-test chart: <name>@<targetRevision>."""
    source = doc["spec"].get("source") or {}
    helm = source.get("helm") or {}
    name = helm.get("releaseName") or source.get("chart")
    if not name and source.get("path"):
        name = source["path"].rstrip("/").rsplit("/", 1)[-1]
    name = name or source.get("repoURL", "").rsplit("/", 1)[-1]
    return f"{name}@{source.get('targetRevision') or 'latest'}"


def mirrored_application(target_dir: Path, app: str, name: str, pr: int) -> tuple[str, str]:
    """Mirror a committed chart Application into a dry-run Application.

    Loads <app>/application.yaml from the PR branch checkout and patches it
    in place: identity (name/namespace/label, no finalizer) and the dry-run
    sync envelope (automated + retry stripped, syncOptions preserved).
    spec.source, spec.destination and spec.project stay verbatim, so the
    chart, targetRevision and values under test are exactly what merges to
    main. Returns (manifest, chart_label).
    """
    if yaml is None:
        raise RuntimeError("PyYAML is required for chart apps")
    path = target_dir / app / "application.yaml"
    try:
        doc = yaml.safe_load(path.read_text())
    except FileNotFoundError:
        raise RuntimeError(f"no application.yaml found at {app}") from None
    meta = dict(doc.get("metadata") or {})
    meta["name"] = name
    meta["namespace"] = "argocd"
    meta.pop("finalizers", None)
    meta["labels"] = {APP_LABEL_KEY: str(pr)}
    doc["metadata"] = meta

    spec = doc["spec"]
    sync_policy = dict(spec.get("syncPolicy") or {})
    sync_policy.pop("automated", None)
    sync_policy.pop("retry", None)
    spec["syncPolicy"] = sync_policy
    return yaml.safe_dump(doc, sort_keys=False), chart_label(doc)


class K8s:
    """Cluster access: runner-pod service account API, kubectl fallback.

    The runner pod mounts its SA token at the standard paths; outside a pod
    (local runs) kubectl with the ambient kubeconfig is used instead.
    """

    def __init__(self):
        self._sa_token = None
        if (SA_BASE / "token").exists():
            self._sa_token = (SA_BASE / "token").read_text().strip()
            self._sa_ca = str(SA_BASE / "ca.crt")

    def _sa_get(self, path: str) -> dict | None:
        req = urllib.request.Request(
            f"https://kubernetes.default.svc{path}",
            headers={"Authorization": f"Bearer {self._sa_token}"},
        )
        ctx = ssl.create_default_context(cafile=self._sa_ca)
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as err:
            if err.code == 404:
                return None
            raise

    def namespace_exists(self, name: str) -> bool:
        """True if the namespace exists (or the check cannot run)."""
        if self._sa_token:
            try:
                return self._sa_get(f"/api/v1/namespaces/{name}") is not None
            except urllib.error.HTTPError:
                # 403: the SA cannot read namespaces; do not fail the app.
                return True
        res = run(["kubectl", "get", "ns", name])
        return res.returncode == 0

    def read_secret(self, namespace: str, name: str, key: str) -> str:
        if self._sa_token:
            doc = self._sa_get(f"/api/v1/namespaces/{namespace}/secrets/{name}")
            if doc is None:
                raise RuntimeError(f"secret {namespace}/{name} not found")
            return base64.b64decode(doc["data"][key]).decode()
        res = run(
            [
                "kubectl",
                "-n",
                namespace,
                "get",
                "secret",
                name,
                "-o",
                f"jsonpath={{.data.{key}}}",
            ]
        )
        if res.returncode != 0:
            raise RuntimeError(
                f"could not read secret {namespace}/{name}: {res.stderr.strip()}"
            )
        return base64.b64decode(res.stdout).decode()


class ArgoCD:
    """Thin wrapper around the argocd CLI (preview-bot API token)."""

    def __init__(self, server: str, token: str):
        # The CLI mangles a scheme in the server address (strips colons); pass the bare host:port and pick the TLS mode. The in-cluster service is plain HTTP (server.insecure=true).
        if server.startswith("https://"):
            self.tls_flags = ["--insecure"]
            server = server[len("https://"):]
        else:
            self.tls_flags = ["--plaintext"]
            server = server.removeprefix("http://")
        self.env = dict(os.environ)
        self.env["ARGOCD_SERVER"] = server
        self.env["ARGOCD_AUTH_TOKEN"] = token

    def run(self, *args: str) -> subprocess.CompletedProcess:
        return run(["argocd", *self.tls_flags, "--grpc-web", *args], env=self.env)

    @staticmethod
    def cli_error(res: subprocess.CompletedProcess) -> str:
        """Human message from the CLI's JSON fatal log lines."""
        for line in reversed(res.stderr.strip().splitlines()):
            line = line.strip()
            if line.startswith("{"):
                try:
                    return json.loads(line).get("msg", line)
                except json.JSONDecodeError:
                    return line
        return res.stderr.strip()

    def create(self, manifest: str) -> str | None:
        """Create an app from a manifest; returns an error message or None.

        --validate=false skips the create-time repo connectivity test, which
        is broken for ghcr.io OCI repos (the oras ping uses a placeholder
        scope that ghcr rejects with 403 even for public charts). The dry-run
        sync is the real validation: it renders the manifests (render errors
        surface there as a ComparisonError) and diffs against the live
        cluster.
        """
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
            f.write(manifest)
            path = f.name
        try:
            for attempt in range(3):
                res = self.run("app", "create", "-f", path, "--validate=false")
                if res.returncode == 0:
                    return None
                err = self.cli_error(res)
                if "502" not in err and "deadline" not in err:
                    return err
                log(f"app create transient failure (attempt {attempt + 1}), retrying")
                time.sleep(10)
            return err
        finally:
            os.unlink(path)

    def get_app(self, name: str) -> dict:
        res = self.run("app", "get", name, "-o", "json")
        if res.returncode != 0:
            raise RuntimeError(f"argocd app get {name} failed:\n{res.stderr.strip()}")
        return json.loads(res.stdout)

    def dry_run_sync(self, name: str, timeout: int = 180) -> dict:
        """Run a dry-run sync and wait for the terminal operation state."""
        self.run("app", "sync", name, "--dry-run", "--timeout", "30")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            doc = self.get_app(name)
            phase = ((doc.get("status") or {}).get("operationState") or {}).get("phase")
            if phase in TERMINAL_PHASES:
                return doc
            time.sleep(5)
        raise TimeoutError(f"dry-run sync did not reach a terminal phase within {timeout}s")

    def delete(self, name: str) -> None:
        res = self.run("app", "delete", name, "--cascade=false")
        if res.returncode != 0:
            log(f"WARN argocd app delete {name} failed: {res.stderr.strip()}")

    def list_by_label(self, label: str) -> list[str]:
        res = self.run("app", "list", "-l", label, "-o", "name")
        if res.returncode != 0:
            raise RuntimeError(f"argocd app list failed:\n{res.stderr.strip()}")
        return [line.strip() for line in res.stdout.splitlines() if line.strip()]


def namespaces_in_app_dir(target_dir: Path, app: str) -> set[str]:
    """Namespaces created by namespace.yaml files in the app directory.

    Chart apps under platform/helm-charts/ ship their Namespace as a
    sibling of application.yaml; the helm-charts parent app applies it, so
    the chart app itself never creates it. The dry-run must not flag such
    namespaces when they do not exist on the host yet (new app).
    """
    names = set()
    for f in sorted((target_dir / app).glob("namespace.yaml")):
        try:
            doc = yaml.safe_load(f.read_text())
        except (OSError, yaml.YAMLError) as err:
            log(f"WARN unparsable namespace.yaml {f}: {err}")
            continue
        if doc and doc.get("kind") == "Namespace":
            name = (doc.get("metadata") or {}).get("name")
            if name:
                names.add(name)
    return names


def namespace_problems(
    spec: dict, op_state: dict, target_dir: Path, app: str, k8s: K8s
) -> list[str]:
    """Namespaces the app targets that neither exist nor are created by it.

    The dry-run sync succeeds even when the destination namespace is
    missing (every resource diffs as Missing), so this supplements it: the
    real sync would fail at apply time with "namespace not found".
    """
    dest_ns = (spec.get("destination") or {}).get("namespace")
    resources = (op_state.get("syncResult") or {}).get("resources") or []
    ns_from_resources = {r.get("namespace") for r in resources if r.get("namespace")}
    created_ns = {r.get("name") for r in resources if r.get("kind") == "Namespace"}
    sync_options = (spec.get("syncPolicy") or {}).get("syncOptions") or []
    if "CreateNamespace=true" in sync_options and dest_ns:
        created_ns.add(dest_ns)
    created_ns |= namespaces_in_app_dir(target_dir, app)

    problems = []
    for ns in sorted({n for n in ({dest_ns} | ns_from_resources) if n} - created_ns):
        if not k8s.namespace_exists(ns):
            problems.append(ns)
    return problems


def sync_failures(op_state: dict) -> list[str]:
    """Per-resource failure lines from the sync result."""
    resources = (op_state.get("syncResult") or {}).get("resources") or []
    lines = []
    for r in resources:
        if r.get("status") == "SyncFailed":
            where = f"{r.get('kind')}/{r.get('name')}"
            if r.get("namespace"):
                where = f"{r.get('namespace')}/{where}"
            lines.append(f"{where}: {r.get('message') or 'sync failed'}")
    return lines


def validate_app(
    argocd: ArgoCD, k8s: K8s, target_dir: Path, app: str, pr: int, repo_url: str, revision: str
) -> tuple[bool, str]:
    """Dry-run validate one app. Returns (ok, detail)."""
    name = app_name(app, pr)
    log(f"validating {app} as {name} ({revision})")
    chart = ""
    if (target_dir / app / "application.yaml").exists():
        manifest, label = mirrored_application(target_dir, app, name, pr)
        chart = f" (chart {label})"
    else:
        manifest = application_manifest(name, repo_url, app, revision, pr)

    err = argocd.create(manifest)
    if err:
        return False, f"create failed: {err[:2000]}{chart}"

    started = time.monotonic()
    try:
        doc = argocd.dry_run_sync(name)
    except (RuntimeError, TimeoutError) as exc:
        argocd.delete(name)
        return False, f"{exc}{chart}"
    elapsed = int(time.monotonic() - started)

    op_state = (doc.get("status") or {}).get("operationState") or {}
    phase = op_state.get("phase")
    problems = namespace_problems(doc.get("spec") or {}, op_state, target_dir, app, k8s)
    argocd.delete(name)

    if phase == "Succeeded" and not problems:
        resources = (op_state.get("syncResult") or {}).get("resources") or []
        return True, f"dry-run Succeeded in {elapsed}s, {len(resources)} resources{chart}"

    lines = [f"dry-run phase: {phase}"]
    if op_state.get("message"):
        lines.append(op_state["message"][:2000])
    lines.extend(sync_failures(op_state))
    for ns in problems:
        lines.append(
            f"namespace {ns} does not exist on the host and the app does not create it"
        )
    return False, "\n".join(lines) + chart


def write_report(
    output: Path, pr: int, changed: list[str], rows: list[str], failures: dict[str, str]
) -> None:
    lines = [f"## ArgoCD dry-run validation report (PR #{pr})", ""]
    lines.append("<details>")
    lines.append("<summary>Changed files</summary>")
    lines.append("")
    lines.append("```text")
    lines.extend(changed)
    lines.append("```")
    lines.append("")
    lines.append("</details>")
    lines.append("")
    lines.append("| App | Result | Details |")
    lines.append("| --- | --- | --- |")
    lines.extend(rows)
    for app, detail in failures.items():
        lines.append("")
        lines.append("<details>")
        lines.append(f"<summary>:x: {app} - failure details</summary>")
        lines.append("")
        lines.append("```text")
        lines.append(detail)
        lines.append("```")
        lines.append("")
        lines.append("</details>")
    lines.append("")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n")


def cleanup(pr: int, argocd: ArgoCD) -> int:
    """Delete leftover dry-run apps for a closed PR (safety net)."""
    label = f"{APP_LABEL_KEY}={pr}"
    apps = argocd.list_by_label(label)
    for name in apps:
        log(f"deleting leftover dry-run app {name}")
        argocd.delete(name)
    if not apps:
        log(f"no dry-run apps left for PR {pr}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-url", help="git repo URL (https)")
    parser.add_argument("--pr", required=True, type=int, help="pull request number")
    parser.add_argument("--base-dir", help="base (main) checkout")
    parser.add_argument("--target-dir", help="target branch checkout")
    parser.add_argument(
        "--argocd-server",
        default="argocd-server.argocd.svc:80",
        help="ArgoCD server address (scheme optional; https:// -> --insecure, else --plaintext)",
    )
    parser.add_argument(
        "--token-secret",
        default="arc-runners/preview-bot-auth:argocd_token",
        help="Secret holding the preview-bot API token (ns/name:key)",
    )
    parser.add_argument("--output", default="output/validation-report.md")
    parser.add_argument(
        "--cleanup",
        action="store_true",
        help="delete leftover dry-run apps for the PR (closed-PR job)",
    )
    args = parser.parse_args()

    k8s = K8s()
    try:
        ns, rest = args.token_secret.split("/", 1)
        secret_name, key = rest.split(":", 1)
        token = k8s.read_secret(ns, secret_name, key)
    except (ValueError, RuntimeError) as err:
        print(f"[argocd-dry-run] FATAL could not read preview-bot token: {err}")
        return 1
    argocd = ArgoCD(args.argocd_server, token)

    if args.cleanup:
        return cleanup(args.pr, argocd)

    if not (args.repo_url and args.base_dir and args.target_dir):
        parser.error("--repo-url, --base-dir and --target-dir are required (or --cleanup)")

    revision = f"{REVISION_PREFIX}/{args.pr}/merge"
    changed = changed_files(Path(args.base_dir), Path(args.target_dir))
    apps = sorted({a for a in (app_for_path(f) for f in changed) if a})
    log(f"changed files: {len(changed)}, apps: {apps}")

    rows = []
    failures: dict[str, str] = {}
    failed = 0
    for app in apps:
        if not (Path(args.target_dir) / app).exists():
            # Removed app: the real sync prunes it; nothing to validate.
            rows.append(f"| {app} | :fast_forward: removed | app directory gone from the PR branch |")
            continue
        try:
            ok, detail = validate_app(
                argocd, k8s, Path(args.target_dir), app, args.pr, args.repo_url, revision
            )
        except RuntimeError as err:
            ok, detail = False, str(err)
        if ok:
            rows.append(f"| {app} | :white_check_mark: applies cleanly | {detail} |")
        else:
            failed += 1
            rows.append(f"| {app} | :x: error | {detail.splitlines()[0][:200]} |")
            failures[app] = detail

    write_report(Path(args.output), args.pr, changed, rows, failures)
    log(f"report written to {args.output}")

    if not apps:
        log("no app changes detected in platform/ or apps/")
    if failed:
        log(f"{failed} app(s) failed validation")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
