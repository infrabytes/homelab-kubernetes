#!/usr/bin/env python3
"""check-renovate-gate.py - fixtures for the breaking-change gate classification.

The gate decides whether a Renovate PR automerges, so its parser and its four verdict
branches are worth pinning: a body shape it misreads either lets a breaking change through
or holds every routine bump. Runs without network and without a GitHub token.
"""

import importlib.util
import sys
from pathlib import Path

GATE = Path(__file__).resolve().parent / "renovate-gate.py"


def load():
    spec = importlib.util.spec_from_file_location("renovate_gate", GATE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def table(*rows):
    lines = ["This PR contains the following updates:", "", "| Package | Update | Change |", "|---|---|---|"]
    lines += [f"| {name} | {update} | `1.0.0` → `1.1.0` |" for name, update in rows]
    return "\n".join(lines) + "\n"


def notes(*blocks):
    body = "\n### Release Notes\n\n"
    for label, text in blocks:
        body += f"<details>\n<summary>{label}</summary>\n\n{text}\n\n</details>\n\n"
    return body


LONG = (
    "##### What's Changed\n\n- **`values.ingress`:** the `tls` key was renamed to `tlsSecret`; "
    "the old key is ignored, so an upgrade silently disables TLS on the ingress.\n- Fix a "
    "reconnect loop in the controller when the API server restarts.\n"
)
LINK_ONLY = "Please refer to the changelog available at https://example.com/changelog\n"


def main():
    gate = load()

    prose_long = gate.notes_prose(LONG)
    prose_link = gate.notes_prose(LINK_ONLY)
    assert prose_long >= gate.MIN_NOTES_PROSE, prose_long
    assert prose_link < gate.MIN_NOTES_PROSE, prose_link

    # Dep name from the update table, matched against a qualified <summary>.
    deps = gate.deps_of(table(("tailscale-operator", "patch")) + notes(("tailscale/tailscale (tailscale-operator)", LINK_ONLY)))
    assert [name for name, _, _ in deps] == ["tailscale-operator"], deps
    assert deps[0][2] is not None and deps[0][2] < gate.MIN_NOTES_PROSE, deps

    # A dep with no <details> block of its own has no notes at all.
    assert gate.deps_of(table(("spegel", "minor")))[0][2] is None

    cases = [
        (
            "major row holds",
            table(("argo-cd", "major")) + notes(("argo-cd", LONG)),
            "",
            False,
            ("failure", "major bump: hold for review"),
        ),
        (
            "major in the title holds",
            table(("argo-cd", "minor")) + notes(("argo-cd", LONG)),
            "chore(deps): update helm release argo-cd to v11 (major)",
            False,
            ("failure", "major bump: hold for review"),
        ),
        (
            "breaking marker holds",
            table(("cilium", "minor"))
            + notes(("cilium", "\nBREAKING CHANGE: the `kubeProxyReplacement` value is gone.\n" + "x" * 200)),
            "",
            False,
            ("failure", "breaking changes in release notes (breaking change mention)"),
        ),
        (
            "clean minor merges",
            table(("cilium", "minor")) + notes(("cilium", LONG)),
            "",
            False,
            ("success", "clean routine update"),
        ),
        (
            "noteless minor holds",
            table(("ghcr.io/spegel-org/helm-charts/spegel", "minor")),
            "",
            False,
            ("failure", "release notes do not say what changed: ghcr.io/spegel-org/helm-charts/spegel"),
        ),
        (
            "link-only minor holds",
            table(("tailscale-operator", "minor")) + notes(("tailscale/tailscale (tailscale-operator)", LINK_ONLY)),
            "",
            False,
            ("failure", "release notes do not say what changed: tailscale-operator"),
        ),
        (
            "noteless patch keeps merging",
            table(("csi-driver-nfs", "patch")),
            "",
            False,
            ("success", "clean routine update"),
        ),
        (
            "group holds only the unverifiable dep",
            table(("ghcr.io/actions/actions-runner", "patch"), ("ghcr.io/onzack/helm-charts/hubble-observer", "minor"))
            + notes(("actions/runner (ghcr.io/actions/actions-runner)", LONG)),
            "",
            False,
            ("failure", "release notes do not say what changed: ghcr.io/onzack/helm-charts/hubble-observer"),
        ),
        (
            "approval overrides every hold",
            table(("argo-cd", "major")),
            "",
            True,
            ("success", "approved by write-access user"),
        ),
    ]

    failures = 0
    for name, body, title, approved, expected in cases:
        state, desc, _ = gate.decide(body, title, approved)
        if (state, desc) == expected:
            print(f"ok   {name}")
        else:
            failures += 1
            print(f"FAIL {name}\n     expected {expected}\n     got      {(state, desc)}")

    # The unverified list is what the analysis job hands the agent, so it must include patches.
    _, _, unverified = gate.decide(table(("csi-driver-nfs", "patch")), "", False)
    if unverified == ["csi-driver-nfs"]:
        print("ok   unverified list carries patch bumps")
    else:
        failures += 1
        print(f"FAIL unverified list: {unverified}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
