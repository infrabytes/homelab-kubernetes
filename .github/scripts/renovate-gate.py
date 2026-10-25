#!/usr/bin/env python3
"""renovate-gate.py - decide the `breaking-change-gate` status for one pull request.

The gate is a text match on the Renovate PR body: a major bump, a breaking-change
marker, or release notes that only link somewhere else. The third case is what the
old gate silently passed; it now holds a minor or major bump and hands the PR to the
`breaking-change-analysis` job, which is what turns the verdict into a PR comment.

Writes the `state`, `pr_number`, `head_sha`, `head_repo`, `reason` and `unverified`
job outputs consumed by .github/workflows/renovate-gate.yaml.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"

RENOVATE_ACTORS = ("renovate[bot]", "infrabytes-renovate[bot]")
BREAKING_PATTERNS = [
    (re.compile(r"\bbreaking[ -]?changes?\b", re.IGNORECASE), "breaking change mention"),
    (re.compile(r"^-*\s*BREAKING[ -]?(CHANGE|CHANGES):", re.MULTILINE), "BREAKING CHANGE trailer"),
    (re.compile(r"^[a-z][a-z]*(\([^)]*\))?!:", re.MULTILINE), "conventional-commit !:"),
]
MAJOR_ROW = re.compile(r"\|\s*major\s*\|", re.IGNORECASE)
MAJOR_TITLE = re.compile(r"[(\[]major[)\]]$", re.IGNORECASE)
UPDATE_TYPES = {"patch", "minor", "major", "pin", "digest", "rollback"}
# Upstream notes that only link to a changelog say nothing about what changed, so below this much prose they count as absent.
MIN_NOTES_PROSE = 160


def headers():
    return {
        "Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
        "Accept": "application/vnd.github+json",
        "User-Agent": "renovate-gate",
    }


def api(path):
    req = urllib.request.Request(API + path, headers=headers())
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def notes_prose(block):
    """Characters of prose in a release-notes block, ignoring markup, URLs and the dep label."""
    text = re.sub(r"<summary>.*?</summary>", "", block, flags=re.DOTALL)
    text = re.sub(r"<[^>]+>", "", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"&[#\w]+;", "", text)
    return len(re.sub(r"\s+", "", text))


def deps_of(body):
    """(name, update type, release-notes prose) per row of the update table."""
    table, _, notes = body.partition("### Release Notes")
    blocks = {}
    for block in re.findall(r"<details>.*?</details>", notes, re.DOTALL):
        summary = re.search(r"<summary>(.*?)</summary>", block, re.DOTALL)
        label = re.sub(r"\s+", " ", summary.group(1)).strip() if summary else ""
        qualified = re.match(r".*?\((.+)\)$", label)
        blocks[(qualified.group(1) if qualified else label).strip()] = notes_prose(block)
    deps = []
    for line in table.splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) < 3 or cells[0].lower().startswith("package"):
            continue
        if set(cells[0]) <= set("-: "):
            continue
        link = re.match(r"\[?([^\]]+?)\]?\(", cells[0])
        name = (link.group(1) if link else cells[0]).strip()
        update = next((cell.lower() for cell in cells[1:] if cell.lower() in UPDATE_TYPES), "")
        deps.append((name, update, blocks.get(name)))
    return deps


def decide(body, title, approved):
    """(state, description, unverified dependencies) for a Renovate PR."""
    deps = deps_of(body)
    unverified = [name for name, _, prose in deps if prose is None or prose < MIN_NOTES_PROSE]
    # A patch bump documented by a bare link keeps automerging; a minor or major one waits.
    holds = [
        name
        for name, update, prose in deps
        if (prose is None or prose < MIN_NOTES_PROSE) and update in ("minor", "major")
    ]
    if approved:
        return "success", "approved by write-access user", unverified
    if MAJOR_ROW.search(body) or MAJOR_TITLE.search(title):
        return "failure", "major bump: hold for review", unverified
    hit = next((label for pattern, label in BREAKING_PATTERNS if pattern.search(body)), None)
    if hit:
        return "failure", f"breaking changes in release notes ({hit})", unverified
    if holds:
        return "failure", "release notes do not say what changed: " + ", ".join(holds), unverified
    return "success", "clean routine update", unverified


def approval(reviews, head_sha):
    """Whether a write-access user's newest review approves this head commit.

    A review is pinned to the commit it was submitted against, so an approval of an
    earlier head (a rebase, or the next Renovate release) says nothing about this one.
    """
    if not head_sha:
        return False
    latest = {}
    for review in reviews:
        latest[review["user"]["login"]] = review
    return any(
        review.get("state") == "APPROVED"
        and review.get("author_association") in {"OWNER", "MEMBER", "COLLABORATOR"}
        and review.get("commit_id") == head_sha
        for review in latest.values()
    )


def post_status(sha, state, description, target_url):
    body = json.dumps(
        {
            "state": state,
            "context": "breaking-change-gate",
            "description": description[:140],
            "target_url": target_url,
        }
    ).encode()
    req = urllib.request.Request(
        f"{API}/repos/{os.environ['GITHUB_REPOSITORY']}/statuses/{sha}",
        data=body,
        method="POST",
        headers=headers(),
    )
    with urllib.request.urlopen(req) as resp:
        return resp.status


def main():
    with open(os.environ["GITHUB_EVENT_PATH"]) as fh:
        event = json.load(fh)

    pr_number = (
        (event.get("pull_request") or {}).get("number")
        or ((event.get("pull_request_review") or {}).get("pull_request") or {}).get("number")
        or (event.get("inputs") or {}).get("pr_number")
    )
    if not pr_number:
        sys.exit("no PR number in event")

    repo = os.environ["GITHUB_REPOSITORY"]
    pr = api(f"/repos/{repo}/pulls/{pr_number}")
    head = pr.get("head") or {}
    head_sha = head.get("sha")
    head_repo = (head.get("repo") or {}).get("full_name") or ""

    if pr["user"]["login"] not in RENOVATE_ACTORS:
        state, desc, unverified = "success", "not a Renovate PR", []
    else:
        reviews = api(f"/repos/{repo}/pulls/{pr_number}/reviews?per_page=100")
        approved = approval(reviews, head_sha)
        state, desc, unverified = decide(pr.get("body") or "", pr.get("title") or "", approved)

    print(f"gate decision: {state} — {desc}")
    print(f"release notes unverifiable for: {', '.join(unverified) or 'none'}")
    try:
        code = post_status(head_sha, state, desc, pr["html_url"])
        print(f"status posted: {code} on {head_sha}")
    except urllib.error.HTTPError as exc:
        if exc.code == 403:
            print("warning: status POST forbidden (fork PR); skipping", file=sys.stderr)
            return
        raise

    outputs = (
        ("state", state),
        ("pr_number", pr_number),
        ("head_sha", head_sha),
        ("head_repo", head_repo),
        ("reason", desc),
        ("unverified", ", ".join(unverified)),
    )
    with open(os.environ["GITHUB_OUTPUT"], "a") as out:
        out.writelines(f"{key}={value}\n" for key, value in outputs)


if __name__ == "__main__":
    main()
