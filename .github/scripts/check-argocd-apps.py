#!/usr/bin/env python3
"""check-argocd-apps.py - validate ArgoCD Application helm sources.

Reproduces what the ArgoCD repo-server does to generate manifests for a
Helm-source Application: resolve the chart revision, pull it, and render it
with `helm template --include-crds` (matching ArgoCD's default; opt-out via
`helm.skipCrds`) using the exact release name, namespace, and values from
the Application manifest. Catches wrong OCI repo paths, missing versions,
typoed values, and template errors before they reach the cluster.

One source kind is rendered:
- "helm": chart/OCI sources (repoURL is a chart repo or OCI registry).

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


def log(msg: str) -> None:
    print(f"[check-argocd-apps] {msg}")


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
    """Build the helm template argv for a pulled chart tarball."""
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


def check_file(path: Path) -> int:
    assert yaml is not None, "PyYAML is required"
    docs = yaml.safe_load_all(path.read_text())
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
        log("one or more ArgoCD apps failed to resolve/render")
    else:
        log("all ArgoCD apps resolved and rendered")
    return failed


if __name__ == "__main__":
    sys.exit(main())
