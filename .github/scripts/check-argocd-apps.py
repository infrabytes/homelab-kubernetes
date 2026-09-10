#!/usr/bin/env python3
"""check-argocd-apps.py - validate ArgoCD Application helm sources.

Reproduces what the ArgoCD repo-server does to generate manifests for a
Helm-source Application: resolve the chart revision, pull it, and render it
with `helm template --include-crds` (matching ArgoCD's default; opt-out via
`helm.skipCrds`) using the exact release name, namespace, and values from
the Application manifest. Catches wrong OCI repo paths, missing versions,
typoed values, and template errors before they reach the cluster.

Three checks run per file:
- Duplicate mapping keys: YAML last-key-wins silently drops earlier values, so
  a repeated key inside `helm.values` (or the Application itself) is a hard
  failure.
- Render: the chart must resolve and template cleanly.
- Resource coverage: every container in the rendered manifests must declare a
  CPU request, a memory request, and a memory limit. Containers the charts
  create without a values knob are listed with a reason in
  resource-coverage-allowlist.yaml.

Usage: check-argocd-apps.py <application.yaml>...
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    yaml = None

POD_KINDS = {
    "Deployment",
    "StatefulSet",
    "DaemonSet",
    "Job",
    "CronJob",
    "Pod",
    "ReplicaSet",
}

ALLOWLIST_PATH = Path(__file__).with_name("resource-coverage-allowlist.yaml")


class DuplicateKeyError(Exception):
    def __init__(self, key, line):
        super().__init__(f"duplicate mapping key {key!r} at line {line}")
        self.key = key
        self.line = line


if yaml is not None:

    class StrictLoader(yaml.SafeLoader):
        """safe_load that rejects duplicate mapping keys (last-key-wins is silent)."""

    def _construct_mapping(loader, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            if key in mapping:
                raise DuplicateKeyError(key, key_node.start_mark.line + 1)
            mapping[key] = loader.construct_object(value_node, deep=deep)
        return mapping

    StrictLoader.add_constructor(
        yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
    )
    # vcluster's rendered CRD contains the bare scalar `- =` (YAML 1.1 value tag).
    StrictLoader.add_constructor(
        "tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node)
    )
else:
    StrictLoader = None


def log(msg: str) -> None:
    print(f"[check-argocd-apps] {msg}")


def load_allowlist():
    """Return {(namespace, workload, container): reason} for sized-by-chart containers."""
    if not ALLOWLIST_PATH.is_file():
        return {}
    data = yaml.safe_load(ALLOWLIST_PATH.read_text()) or {}
    entries = {}
    for entry in data.get("allow") or []:
        key = (entry.get("namespace"), entry.get("workload"), entry.get("container"))
        entries[key] = entry.get("reason", "no reason given")
    return entries


def pod_containers(doc):
    """Yield (container_name, resources, kind, workload) for pod-bearing docs."""
    kind = doc.get("kind")
    name = (doc.get("metadata") or {}).get("name", "?")
    if kind in POD_KINDS:
        spec = doc.get("spec") or {}
        if kind == "CronJob":
            pod_spec = ((spec.get("jobTemplate") or {}).get("spec") or {}).get(
                "template", {}
            ).get("spec") or {}
        elif kind == "Pod":
            pod_spec = spec
        else:
            pod_spec = (spec.get("template") or {}).get("spec") or {}
        containers = (pod_spec.get("containers") or []) + (
            pod_spec.get("initContainers") or []
        )
        for container in containers:
            yield container.get("name"), container.get("resources") or {}, kind, name
    elif kind == "Alloy":
        alloy = (doc.get("spec") or {}).get("alloy") or {}
        yield "alloy", alloy.get("resources") or {}, kind, name
    elif kind == "Collector":
        yield "collector", (doc.get("spec") or {}).get("resources") or {}, kind, name


def coverage_problems(rendered, dest_ns, app, allowlist):
    problems = []
    for doc in yaml.load_all(rendered, Loader=StrictLoader):
        if not isinstance(doc, dict) or doc.get("kind") == "CustomResourceDefinition":
            continue
        namespace = (doc.get("metadata") or {}).get("namespace") or dest_ns
        for name, resources, kind, workload in pod_containers(doc):
            requests = resources.get("requests") or {}
            limits = resources.get("limits") or {}
            missing = [
                label
                for label, present in (
                    ("cpu request", requests.get("cpu")),
                    ("memory request", requests.get("memory")),
                    ("memory limit", limits.get("memory")),
                )
                if not present
            ]
            if not missing:
                continue
            key = (namespace, workload, name)
            if key in allowlist:
                continue
            problems.append(
                f"{namespace}/{kind}/{workload} container {name}: "
                f"missing {', '.join(missing)} ({app})"
            )
    return problems


def run(cmd, **kwargs):
    return subprocess.run(cmd, capture_output=True, text=True, check=False, **kwargs)


def helm_sources(doc):
    """Yield (app_name, source, dest_namespace, kind) for helm-rendered sources.

    kind is always "helm" (chart or OCI registry sources). Sources with
    neither a chart nor a path (plain manifest apps) are skipped.
    """
    spec = doc.get("spec") or {}
    dest_ns = (spec.get("destination") or {}).get("namespace") or "default"
    sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
    for src in sources:
        if src.get("ref"):
            continue
        repo = src.get("repoURL") or ""
        is_oci = repo.startswith("oci://")
        if src.get("chart") or is_oci:
            yield (doc.get("metadata") or {}).get("name", "?"), src, dest_ns, "helm"


def pull_args(source):
    """Return (helm pull argv, release_name) for a source."""
    repo = source["repoURL"]
    chart = source.get("chart", "")
    rev = source.get("targetRevision", "")
    version = ["--version", rev] if rev else []

    if repo.startswith("oci://"):
        return ["helm", "pull", repo, *version], chart or repo.rsplit("/", 1)[-1]
    if chart:
        if repo.startswith(("http://", "https://")):
            return ["helm", "pull", chart, "--repo", repo, *version], chart
        # scheme-less OCI-enabled helm repo (e.g. quay.io/..., ghcr.io/...)
        return ["helm", "pull", f"oci://{repo}/{chart}", *version], chart
    raise ValueError(f"unrecognized helm source: {repo} chart={chart!r}")


def values_args(work_dir, helm_block):
    """Write values files and return the helm --values/--set argv."""
    assert yaml is not None, "PyYAML is required"
    args = []
    values = helm_block.get("values")
    if values is not None:
        f = work_dir / "values.yaml"
        f.write_text(values)
        args += ["--values", str(f)]
    values_object = helm_block.get("valuesObject")
    if values_object is not None:
        f = work_dir / "values-object.yaml"
        f.write_text(yaml.safe_dump(values_object))
        args += ["--values", str(f)]
    for p in helm_block.get("parameters") or []:
        flag = "--set-string" if p.get("forceString") else "--set"
        args += [flag, f"{p['name']}={p['value']}"]
    return args


def template_args(work_dir, release, source, dest_ns, helm_block):
    args = ["helm", "template", release]
    chart_paths = sorted(work_dir.glob("*.tgz"))
    if not chart_paths:
        raise FileNotFoundError(f"no chart tarball pulled into {work_dir}")
    args.append(str(chart_paths[0]))
    args += ["--namespace", dest_ns]
    # ArgoCD renders charts with --include-crds unless helm.skipCrds is set.
    if not helm_block.get("skipCrds"):
        args += ["--include-crds"]
    args += values_args(work_dir, helm_block)
    return args


def check_values_duplicates(helm_block) -> None:
    values = helm_block.get("values")
    if isinstance(values, str):
        list(yaml.load_all(values, Loader=StrictLoader))


def check_file(path: Path) -> int:
    assert yaml is not None, "PyYAML is required"
    try:
        docs = list(yaml.load_all(path.read_text(), Loader=StrictLoader))
    except DuplicateKeyError as err:
        log(f"FAIL {path}: duplicate mapping key in the Application: {err}")
        return 1
    allowlist = load_allowlist()
    for doc in docs:
        if not isinstance(doc, dict) or doc.get("kind") != "Application":
            continue
        for app, source, dest_ns, kind in helm_sources(doc):
            helm_block = source.get("helm") or {}
            if helm_block.get("valueFiles"):
                log(f"WARN {path}: {app} uses helm.valueFiles (not checked)")
            rev = source.get("targetRevision") or "latest"
            with tempfile.TemporaryDirectory(prefix="argocd-apps.") as tmp:
                tmp = Path(tmp)
                try:
                    check_values_duplicates(helm_block)
                    release = helm_block.get("releaseName") or source.get("chart", "")
                    pull, default_release = pull_args(source)
                    res = run(pull + ["--destination", str(tmp)])
                    if res.returncode != 0:
                        raise RuntimeError(f"helm pull failed:\n{res.stderr.strip()}")
                    release = release or default_release
                    args = template_args(tmp, release, source, dest_ns, helm_block)
                    res = run(args)
                    if res.returncode != 0:
                        raise RuntimeError(
                            f"helm template failed:\n{res.stderr.strip()}"
                        )
                    problems = coverage_problems(res.stdout, dest_ns, app, allowlist)
                    if problems:
                        raise RuntimeError(
                            "containers without cpu request/memory request/memory limit:\n  "
                            + "\n  ".join(problems)
                            + f"\n  add resources in {path} or an allowlist entry (with reason) in {ALLOWLIST_PATH.name}"
                        )
                except Exception as err:  # noqa: BLE001
                    log(f"FAIL {path}: {app} ({source['repoURL']}@{rev}): {err}")
                    return 1
            log(f"OK   {path}: {app} ({release}@{rev}, ns {dest_ns})")
    return 0


def main() -> int:
    if not shutil.which("helm"):
        log("helm not found, skipping (install helm to validate ArgoCD apps)")
        return 0
    if yaml is None:
        log("PyYAML not found, skipping (pip install pyyaml to validate ArgoCD apps)")
        return 0
    paths = [Path(p) for p in sys.argv[1:]]
    if not paths:
        log("no files given")
        return 0
    failed = 0
    for p in paths:
        if not p.is_file():
            log(f"SKIP {p}: not a file")
            continue
        failed |= check_file(p)
    if failed:
        log("one or more ArgoCD apps failed to resolve/render or have unsized containers")
    else:
        log("all ArgoCD apps resolved, rendered, and sized")
    return failed


if __name__ == "__main__":
    sys.exit(main())
