#!/usr/bin/env python3
"""renovate-atlantis-apply.py: request Atlantis apply on green Renovate infra PRs.

Driven by .github/workflows/renovate-atlantis-apply.yaml, which fires when the
`pre-commit` or `renovate-gate` workflow completes or when any commit status
changes. The status trigger is what lets an apply request land when Atlantis
plans slower than those two workflows: the aggregate `atlantis/plan` update is
commonly the last gate to turn green. Resolves the pull request behind the
triggering SHA and comments `atlantis apply` once every gate on that SHA is
green, so Atlantis applies the units and merges without a human in the loop.

The comment body is deliberately the bare single line `atlantis apply`:
Atlantis ignores a comment whose body has a second non-empty line
(multiLineRegex), so a hidden dedupe marker cannot be smuggled in. Duplicate
suppression therefore compares the bot's own apply comments against the head
commit's committer date.

Usage:
    renovate-atlantis-apply.py              # decide and act (needs GITHUB_TOKEN)
    renovate-atlantis-apply.py --self-test  # offline fixtures for evaluate()
"""

import datetime
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

API_ROOT = "https://api.github.com"
TRIGGER_WORKFLOWS = frozenset({"pre-commit", "renovate-gate"})
RENOVATE_LOGIN = "renovate[bot]"
BOT_LOGIN = "github-actions[bot]"
INFRA_PREFIX = "infra/"
APPLY_COMMENT = "atlantis apply"
PLAN_CONTEXT = "atlantis/plan"
GREEN_CONCLUSIONS = frozenset({"success", "neutral", "skipped"})


def log(message: str) -> None:
    print(f"[renovate-atlantis-apply] {message}", flush=True)


def parse_ts(value: str) -> datetime.datetime:
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def newest_status(statuses: list[dict], context: str) -> dict | None:
    matches = [status for status in statuses if status.get("context") == context]
    if not matches:
        return None
    return max(matches, key=lambda status: status.get("created_at") or "")


def has_apply_comment(comments: list[dict], since: str) -> bool:
    threshold = parse_ts(since)
    for comment in comments:
        if (comment.get("user") or {}).get("login") != BOT_LOGIN:
            continue
        if (comment.get("body") or "").strip() != APPLY_COMMENT:
            continue
        if parse_ts(comment["created_at"]) >= threshold:
            return True
    return False


def own_check_run(check_run: dict, run_id: str) -> bool:
    return bool(run_id) and run_id in (check_run.get("details_url") or "")


def evaluate(
    *,
    pr: dict,
    files: list[str],
    check_runs: list[dict],
    combined_state: str,
    statuses: list[dict],
    comments: list[dict],
    head_committer_date: str,
    run_sha: str,
    run_id: str,
) -> tuple[bool, str]:
    """Pure gate evaluation: (should_apply, reason)."""
    if pr.get("state") != "open":
        return False, f"pr is {pr.get('state')}"

    author = (pr.get("user") or {}).get("login")
    if author != RENOVATE_LOGIN:
        return False, f"author {author!r} is not {RENOVATE_LOGIN}"

    head_sha = (pr.get("head") or {}).get("sha")
    if head_sha != run_sha:
        return False, f"pr head {head_sha} moved past run sha {run_sha}"

    if not any(name.startswith(INFRA_PREFIX) for name in files):
        return False, f"no {INFRA_PREFIX}** files"

    for check_run in check_runs:
        if own_check_run(check_run, run_id):
            continue
        if check_run.get("status") != "completed":
            return False, f"check run {check_run.get('name')} is {check_run.get('status')}"
        if check_run.get("conclusion") not in GREEN_CONCLUSIONS:
            return False, f"check run {check_run.get('name')} is {check_run.get('conclusion')}"

    if combined_state != "success":
        return False, f"combined commit status is {combined_state}"

    plan = newest_status(statuses, PLAN_CONTEXT)
    if plan is None:
        return False, f"no {PLAN_CONTEXT} status on {run_sha}"
    if plan.get("state") != "success":
        return False, f"{PLAN_CONTEXT} is {plan.get('state')}"

    if has_apply_comment(comments, head_committer_date):
        return False, f"apply already requested on {run_sha}"

    return True, f"green: posting {APPLY_COMMENT!r} on {run_sha}"


def build_headers(*, body: bool) -> dict:
    headers = {
        "Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
        "Accept": "application/vnd.github+json",
        "User-Agent": "renovate-atlantis-apply",
    }
    if body:
        headers["Content-Type"] = "application/json"
    return headers


def request(url: str, *, method: str = "GET", payload: dict | None = None) -> tuple[object, dict]:
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers=build_headers(body=body is not None))
    with urllib.request.urlopen(req) as response:
        raw = response.read()
        return (json.loads(raw) if raw else None), dict(response.headers)


def api(path: str, *, method: str = "GET", payload: dict | None = None) -> object:
    return request(API_ROOT + path, method=method, payload=payload)[0]


def next_link(header: str | None) -> str | None:
    for part in (header or "").split(","):
        if 'rel="next"' in part:
            return part.split(";")[0].strip().strip("<>")
    return None


def api_pages(path: str, *, key: str | None = None) -> list:
    items: list = []
    url = API_ROOT + path
    while url:
        page, headers = request(url)
        items.extend(page if key is None else page.get(key, []))
        url = next_link(headers.get("Link"))
    return items


def resolve_pr_number(workflow_run: dict, repo: str, sha: str) -> int | None:
    for candidate in workflow_run.get("pull_requests") or []:
        return candidate.get("number")
    for pull in api_pages(f"/repos/{repo}/commits/{sha}/pulls"):
        if pull.get("state") == "open":
            return pull["number"]
    return None


def trigger_sha(event: dict, event_name: str) -> str | None:
    """SHA whose gates this event asks us to judge, or None when it is not ours.

    The `status` event's commit is in the payload: the run itself executes in the
    default-branch context, so GITHUB_SHA there is main, not the commit to judge.
    """
    if event_name == "workflow_run":
        run = event.get("workflow_run") or {}
        if event.get("action") != "completed" or run.get("name") not in TRIGGER_WORKFLOWS:
            return None
        return run.get("head_sha") or None
    if event_name == "status":
        return event.get("sha") or None
    return None


def main() -> int:
    with open(os.environ["GITHUB_EVENT_PATH"]) as handle:
        event = json.load(handle)
    sha = trigger_sha(event, os.environ.get("GITHUB_EVENT_NAME", ""))
    if sha is None:
        return 0

    repo = os.environ["GITHUB_REPOSITORY"]
    run_id = os.environ.get("GITHUB_RUN_ID", "")

    pr_number = resolve_pr_number(event.get("workflow_run") or {}, repo, sha)
    if pr_number is None:
        log(f"skip: no pull request for {sha}")
        return 0

    pr = api(f"/repos/{repo}/pulls/{pr_number}")
    files = [entry["filename"] for entry in api_pages(f"/repos/{repo}/pulls/{pr_number}/files?per_page=100")]
    check_runs = api_pages(f"/repos/{repo}/commits/{sha}/check-runs?per_page=100", key="check_runs")
    combined_state = api(f"/repos/{repo}/commits/{sha}/status")["state"]
    statuses = api_pages(f"/repos/{repo}/commits/{sha}/statuses?per_page=100")
    comments = api_pages(f"/repos/{repo}/issues/{pr_number}/comments?per_page=100")
    head_committer_date = api(f"/repos/{repo}/commits/{sha}")["commit"]["committer"]["date"]

    should_apply, reason = evaluate(
        pr=pr,
        files=files,
        check_runs=check_runs,
        combined_state=combined_state,
        statuses=statuses,
        comments=comments,
        head_committer_date=head_committer_date,
        run_sha=sha,
        run_id=run_id,
    )
    log(f"pr #{pr_number} {sha}: {reason}")
    if not should_apply:
        return 0

    api(f"/repos/{repo}/issues/{pr_number}/comments", method="POST", payload={"body": APPLY_COMMENT})
    log(f"posted {APPLY_COMMENT!r} on pr #{pr_number}")
    return 0


FIXTURE_SHA = "b" * 40
FIXTURE_RUN_ID = "35124540371"
FIXTURE_HEAD_DATE = "2026-09-16T10:00:00Z"


def fixture(**overrides) -> dict:
    base = {
        "pr": {"state": "open", "user": {"login": RENOVATE_LOGIN}, "head": {"sha": FIXTURE_SHA}},
        "files": ["infra/env.hcl", "platform/observability/grafana.yaml"],
        "check_runs": [
            {
                "name": "pre-commit",
                "status": "completed",
                "conclusion": "success",
                "details_url": "https://github.com/o/r/actions/runs/1/job/11",
            },
            {
                "name": "breaking-change-gate",
                "status": "completed",
                "conclusion": "success",
                "details_url": "https://github.com/o/r/actions/runs/2/job/22",
            },
        ],
        "combined_state": "success",
        "statuses": [{"context": PLAN_CONTEXT, "state": "success", "created_at": "2026-09-16T10:30:00Z"}],
        "comments": [],
        "head_committer_date": FIXTURE_HEAD_DATE,
        "run_sha": FIXTURE_SHA,
        "run_id": FIXTURE_RUN_ID,
    }
    base.update(overrides)
    return base


SELF_TEST_CASES = [
    ("happy path", fixture(), True, "posting"),
    ("closed pr", fixture(pr={"state": "closed", "user": {"login": RENOVATE_LOGIN}, "head": {"sha": FIXTURE_SHA}}), False, "pr is closed"),
    ("non-renovate author", fixture(pr={"state": "open", "user": {"login": "bbayrakt"}, "head": {"sha": FIXTURE_SHA}}), False, "not renovate[bot]"),
    ("pr head moved past run sha", fixture(pr={"state": "open", "user": {"login": RENOVATE_LOGIN}, "head": {"sha": "c" * 40}}), False, "moved past"),
    ("no infra files", fixture(files=[".pre-commit-config.yaml"]), False, "no infra/**"),
    (
        "pending check run",
        fixture(
            check_runs=[
                {"name": "pre-commit", "status": "in_progress", "conclusion": None, "details_url": "https://github.com/o/r/actions/runs/1/job/11"}
            ]
        ),
        False,
        "pre-commit is in_progress",
    ),
    (
        "failed check run",
        fixture(
            check_runs=[
                {"name": "breaking-change-gate", "status": "completed", "conclusion": "failure", "details_url": "https://github.com/o/r/actions/runs/2/job/22"}
            ]
        ),
        False,
        "breaking-change-gate is failure",
    ),
    ("red breaking-change-gate status", fixture(combined_state="failure"), False, "combined commit status is failure"),
    (
        "pending status blocks",
        fixture(statuses=[{"context": "atlantis/apply", "state": "pending", "created_at": "2026-09-16T10:30:00Z"}, {"context": PLAN_CONTEXT, "state": "success", "created_at": "2026-09-16T10:30:00Z"}], combined_state="pending"),
        False,
        "combined commit status is pending",
    ),
    (
        "own check run ignored",
        fixture(
            check_runs=[
                {"name": "pre-commit", "status": "completed", "conclusion": "success", "details_url": "https://github.com/o/r/actions/runs/1/job/11"},
                {"name": "breaking-change-gate", "status": "completed", "conclusion": "success", "details_url": "https://github.com/o/r/actions/runs/2/job/22"},
                {"name": "request-apply", "status": "in_progress", "conclusion": None, "details_url": f"https://github.com/o/r/actions/runs/{FIXTURE_RUN_ID}/job/33"},
            ]
        ),
        True,
        "posting",
    ),
    ("missing atlantis/plan status", fixture(statuses=[]), False, "no atlantis/plan status"),
    ("failed atlantis/plan status", fixture(statuses=[{"context": PLAN_CONTEXT, "state": "failure", "created_at": "2026-09-16T10:30:00Z"}]), False, "atlantis/plan is failure"),
    ("pending atlantis/plan status", fixture(statuses=[{"context": PLAN_CONTEXT, "state": "pending", "created_at": "2026-09-16T10:30:00Z"}]), False, "atlantis/plan is pending"),
    (
        "newest atlantis/plan wins",
        fixture(
            statuses=[
                {"context": PLAN_CONTEXT, "state": "pending", "created_at": "2026-09-16T10:31:00Z"},
                {"context": PLAN_CONTEXT, "state": "success", "created_at": "2026-09-16T10:30:00Z"},
            ]
        ),
        False,
        "atlantis/plan is pending",
    ),
    (
        "prior apply comment belongs to an older sha",
        fixture(comments=[{"user": {"login": BOT_LOGIN}, "body": APPLY_COMMENT, "created_at": "2026-09-15T10:00:00Z"}]),
        True,
        "posting",
    ),
    (
        "prior apply comment on this sha",
        fixture(comments=[{"user": {"login": BOT_LOGIN}, "body": f" {APPLY_COMMENT}\n", "created_at": "2026-09-16T11:00:00Z"}]),
        False,
        "apply already requested",
    ),
    (
        "human apply comment is not dedupe",
        fixture(comments=[{"user": {"login": "bbayrakt"}, "body": APPLY_COMMENT, "created_at": "2026-09-16T11:00:00Z"}]),
        True,
        "posting",
    ),
    (
        "multi-line bot comment is not the apply marker",
        fixture(comments=[{"user": {"login": BOT_LOGIN}, "body": f"{APPLY_COMMENT}\n<!-- renovate-atlantis-apply -->", "created_at": "2026-09-16T11:00:00Z"}]),
        True,
        "posting",
    ),
]


def workflow_run_event() -> dict:
    return {
        "action": "completed",
        "workflow_run": {
            "name": "pre-commit",
            "head_sha": FIXTURE_SHA,
            "id": FIXTURE_RUN_ID,
            "pull_requests": [{"number": 7}],
        },
    }


def status_event() -> dict:
    return {"sha": FIXTURE_SHA, "context": PLAN_CONTEXT, "state": "success"}


TRIGGER_SHA_CASES = [
    ("trigger: completed run of ours", "workflow_run", workflow_run_event(), FIXTURE_SHA),
    ("trigger: completed run of another workflow", "workflow_run", {"action": "completed", "workflow_run": {"name": "pr-preview"}}, None),
    ("trigger: run is not completed", "workflow_run", {"action": "requested", "workflow_run": {"name": "pre-commit"}}, None),
    ("trigger: status event", "status", status_event(), FIXTURE_SHA),
    ("trigger: status event without sha", "status", {"context": PLAN_CONTEXT, "state": "success"}, None),
    ("trigger: unrelated event", "push", {"after": FIXTURE_SHA}, None),
]

OWN_CHECK_RUN = {
    "name": "request-apply",
    "status": "in_progress",
    "conclusion": None,
    "details_url": f"https://github.com/o/r/actions/runs/{FIXTURE_RUN_ID}/job/33",
}


MAIN_CASES = [
    {
        "name": "main: workflow_run posts one apply comment when green",
        "event_name": "workflow_run",
        "event": workflow_run_event(),
        "combined_state": "success",
        "expect_post": True,
    },
    {
        "name": "main: workflow_run posts nothing when a status is red",
        "event_name": "workflow_run",
        "event": workflow_run_event(),
        "combined_state": "failure",
        "expect_post": False,
    },
    {
        "name": "main: status event posts one apply comment when green",
        "event_name": "status",
        "event": status_event(),
        "combined_state": "success",
        "expect_post": True,
    },
    {
        "name": "main: status event posts nothing when a status is red",
        "event_name": "status",
        "event": status_event(),
        "combined_state": "failure",
        "expect_post": False,
    },
    {
        "name": "main: own in-flight check run does not block posting",
        "event_name": "status",
        "event": status_event(),
        "combined_state": "success",
        "expect_post": True,
        "extra_check_runs": [OWN_CHECK_RUN],
    },
]


def stub_responses(sha: str, *, combined_state: str, extra_check_runs: list | None = None) -> dict:
    return {
        "/repos/o/r/pulls/7": {"state": "open", "user": {"login": RENOVATE_LOGIN}, "head": {"sha": sha}},
        "/repos/o/r/pulls/7/files": [{"filename": "infra/env.hcl"}],
        f"/repos/o/r/commits/{sha}/pulls": [{"number": 7, "state": "open"}],
        f"/repos/o/r/commits/{sha}/check-runs": {
            "check_runs": [
                {"name": "pre-commit", "status": "completed", "conclusion": "success", "details_url": "https://github.com/o/r/actions/runs/1/job/11"},
                *(extra_check_runs or []),
            ]
        },
        f"/repos/o/r/commits/{sha}/status": {"state": combined_state},
        f"/repos/o/r/commits/{sha}/statuses": [{"context": PLAN_CONTEXT, "state": "success", "created_at": "2026-09-16T10:30:00Z"}],
        "/repos/o/r/issues/7/comments": [],
        f"/repos/o/r/commits/{sha}": {"commit": {"committer": {"date": FIXTURE_HEAD_DATE}}},
    }


def run_main_case(
    name: str,
    *,
    event_name: str,
    event: dict,
    combined_state: str,
    expect_post: bool,
    extra_check_runs: list | None = None,
) -> int:
    """Drive main() end to end over a stubbed transport, asserting what it posts."""
    sha = FIXTURE_SHA
    responses = stub_responses(sha, combined_state=combined_state, extra_check_runs=extra_check_runs)
    posts: list = []

    def stub(url: str, *, method: str = "GET", payload: dict | None = None) -> tuple[object, dict]:
        path = url.replace(API_ROOT, "").split("?")[0]
        if method != "GET":
            posts.append((path, method, payload))
            return {}, {}
        if path not in responses:
            raise AssertionError(f"unexpected GET {path}")
        return responses[path], {}

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(event, handle)
        event_path = handle.name

    env_keys = ("GITHUB_EVENT_NAME", "GITHUB_EVENT_PATH", "GITHUB_REPOSITORY", "GITHUB_TOKEN", "GITHUB_RUN_ID")
    original_env = {key: os.environ.get(key) for key in env_keys}
    original_request = globals()["request"]
    globals()["request"] = stub
    os.environ.update(
        {
            "GITHUB_EVENT_NAME": event_name,
            "GITHUB_EVENT_PATH": event_path,
            "GITHUB_REPOSITORY": "o/r",
            "GITHUB_TOKEN": "self-test",
            "GITHUB_RUN_ID": FIXTURE_RUN_ID,
        }
    )
    try:
        return_code = main()
    finally:
        globals()["request"] = original_request
        for key, value in original_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        os.unlink(event_path)

    expected = [("/repos/o/r/issues/7/comments", "POST", {"body": APPLY_COMMENT})] if expect_post else []
    ok = return_code == 0 and posts == expected
    print(f"{'PASS' if ok else 'FAIL'} {name}: posts={posts}")
    return 0 if ok else 1


def self_test() -> int:
    assert APPLY_COMMENT.strip() == APPLY_COMMENT and "\n" not in APPLY_COMMENT, "comment must be one line for multiLineRegex"
    os.environ.setdefault("GITHUB_TOKEN", "self-test")
    assert build_headers(body=True)["Content-Type"] == "application/json", "JSON bodies must declare their content type"
    assert "Content-Type" not in build_headers(body=False), "bodyless requests must not claim a content type"
    failures = 0
    for name, event_name, event, expect_sha in TRIGGER_SHA_CASES:
        sha = trigger_sha(event, event_name)
        ok = sha is expect_sha
        print(f"{'PASS' if ok else 'FAIL'} {name}: sha={sha!r}")
        failures += 0 if ok else 1
    for name, kwargs, expect_apply, expect_reason in SELF_TEST_CASES:
        should_apply, reason = evaluate(**kwargs)
        ok = should_apply is expect_apply and expect_reason in reason
        print(f"{'PASS' if ok else 'FAIL'} {name}: {reason}")
        failures += 0 if ok else 1
    for case in MAIN_CASES:
        failures += run_main_case(**case)
    total = len(TRIGGER_SHA_CASES) + len(SELF_TEST_CASES) + len(MAIN_CASES)
    print(f"{total - failures}/{total} fixtures passed")
    return 1 if failures else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["--self-test"]:
        sys.exit(self_test())
    if args:
        sys.exit(f"usage: {sys.argv[0]} [--self-test]")
    try:
        sys.exit(main())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:800]
        log(f"error: HTTP {exc.code} on {exc.url}: {detail}")
        sys.exit(1)
