"""File-backed pull request board for the Mac status server."""

import calendar
import json
import os
import re
import tempfile
import threading
import time
import urllib.error
import urllib.request

from github_actions import load_token


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("MAC_STATUS_PULL_REQUESTS_CONFIG") or os.path.join(
    BASE_DIR, "pull-requests.json"
)
GITHUB_GRAPHQL = "https://api.github.com/graphql"
JIRA_BROWSE = "https://tangem.atlassian.net/browse/"
CACHE_SECONDS = 60
PAGE_SIZE = 50
MAX_PAGES = 20

# Only pull requests touched within this window are loaded. GitHub bumps `updated` on a comment,
# a review, a push and a label change alike, so the cutoff means "nothing happened here for a
# month" — such a pull request is abandoned, not work in progress, and only makes the board long.
FRESH_DAYS = 30

# How deep the discussion is read. Only the tail matters: the board answers "is there anything
# new after the last change request", not "show the whole thread". Overflow is reported as such.
RECENT_COMMENTS = 30
RECENT_THREADS = 30
THREAD_REPLIES = 3
RECENT_REVIEWS = 30
RECENT_COMMITS = 40

# Commits carry the authoring date, not the moment they landed on the branch: GitHub no longer
# exposes a push time. Commits written within this window are shown as one push — a series of
# local commits sent at once reads as one event, which is what the timeline is about.
PUSH_GAP_SECONDS = 600

# A review submitted with a body and inline notes arrives twice: as a COMMENTED review and as
# the thread comments themselves. The review is dropped when its author left a thread comment
# this close to it, so one act of commenting is one event.
REVIEW_ECHO_SECONDS = 120

# Titles carry the task key in three shapes: "JS-7383: ...", "[IT-2416] ..." and "Js 6546 ...".
# The strict form wins; the loose one is tried only at the beginning of the title, so version
# numbers and stray words in the middle cannot pass for a task.
JIRA_STRICT = re.compile(r"\b([A-Z][A-Z0-9]{1,9})-(\d{1,6})\b")
JIRA_LOOSE = re.compile(r"^\W*([A-Za-z]{2,6})[-_\s](\d{2,6})\b")

_CACHE_LOCK = threading.Lock()
_CACHE = {"at": 0, "value": None}

QUERY = """
query($q: String!, $size: Int!, $cursor: String) {
  viewer { login }
  search(query: $q, type: ISSUE, first: $size, after: $cursor) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number
        title
        url
        isDraft
        createdAt
        updatedAt
        totalCommentsCount
        author { login }
        repository { name }
        reviewDecision
        approvals: reviews(states: APPROVED) { totalCount }
        changeRequests: reviews(states: CHANGES_REQUESTED) { totalCount }
        reviews(last: %(reviews)d) {
          nodes { state submittedAt author { login } }
        }
        comments(last: %(comments)d) {
          nodes { createdAt author { login } }
        }
        reviewThreads(last: %(threads)d) {
          nodes {
            isResolved
            comments(last: %(replies)d) {
              nodes { createdAt author { login } }
            }
          }
        }
        commits(last: %(commits)d) {
          nodes { commit { committedDate } }
        }
      }
    }
  }
}
""" % {
    "reviews": RECENT_REVIEWS,
    "comments": RECENT_COMMENTS,
    "threads": RECENT_THREADS,
    "replies": THREAD_REPLIES,
    "commits": RECENT_COMMITS,
}


def _validate_config(config):
    """Validate and normalize the JSON structure before API handlers use it."""
    if not isinstance(config, dict):
        raise ValueError("config must be an object")
    owner = str(config.get("owner") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", owner):
        raise ValueError("invalid owner")
    repos = config.get("repos")
    if not isinstance(repos, list):
        raise ValueError("repos must be an array")
    normalized = []
    for item in repos:
        repo = str(item or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", repo):
            raise ValueError("invalid repository name")
        if repo not in normalized:
            normalized.append(repo)
    normalized.sort()
    return {"owner": owner, "repos": normalized}


def load_config():
    """Read the repository list on every request so manual file edits take effect."""
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
            return _validate_config(json.load(handle))
    except FileNotFoundError:
        return {"owner": "tangem-developments", "repos": []}


def _save_config(config):
    """Atomically replace the config to prevent partial writes on interruption."""
    config = _validate_config(config)
    directory = os.path.dirname(CONFIG_PATH)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".pull-requests-", suffix=".json", dir=directory
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(config, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, CONFIG_PATH)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    with _CACHE_LOCK:
        _CACHE.update({"at": 0, "value": None})
    return config


def edit_config(data):
    """Add or remove one repository and persist the adjacent JSON config."""
    try:
        config = load_config()
        op = str(data.get("op") or "")
        repo = str(data.get("repo") or "").strip()
        if op == "remove":
            if repo not in config["repos"]:
                return {"ok": False, "msg": "repository not found"}
            config["repos"] = [item for item in config["repos"] if item != repo]
        elif op == "add":
            if repo in config["repos"]:
                return {"ok": False, "msg": "repository already exists"}
            config["repos"].append(repo)
        else:
            return {"ok": False, "msg": "unknown config operation"}
        saved = _save_config(config)
        return {"ok": True, "msg": "saved", "count": len(saved["repos"])}
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {"ok": False, "msg": str(exc)}


def _graphql(variables):
    """Call the GitHub GraphQL API with the private work token."""
    token = load_token()
    if not token:
        raise RuntimeError("work GitHub token is not configured")
    body = json.dumps({"query": QUERY, "variables": variables}).encode("utf-8")
    request = urllib.request.Request(
        GITHUB_GRAPHQL,
        data=body,
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "User-Agent": "cloudlyru-mac-status",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            payload = json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        raise RuntimeError("GitHub API %s" % exc.code)
    except urllib.error.URLError as exc:
        raise RuntimeError("GitHub API unavailable: %s" % exc.reason)
    errors = payload.get("errors")
    if errors:
        message = str((errors[0] or {}).get("message") or "query failed")
        raise RuntimeError("GitHub API: " + message)
    return payload.get("data") or {}


def task_key(title):
    """Extract the Jira key from a pull request title, or an empty string."""
    strict = JIRA_STRICT.search(title or "")
    if strict:
        return "%s-%s" % (strict.group(1), strict.group(2))
    loose = JIRA_LOOSE.match(title or "")
    if loose:
        return "%s-%s" % (loose.group(1).upper(), loose.group(2))
    return ""


def _discussion(node, author):
    """Collect every recent comment of a pull request except the author's own replies.

    Self-replies are dropped on purpose: the board exists to show what other people said, and
    an answer of mine to a review is not a reason to look at the pull request again.
    """
    items = []
    for comment in (node.get("comments") or {}).get("nodes") or []:
        if not comment:
            continue
        login = ((comment.get("author") or {}).get("login")) or ""
        if login and login != author:
            items.append((comment.get("createdAt") or "", login))
    for thread in (node.get("reviewThreads") or {}).get("nodes") or []:
        for comment in ((thread or {}).get("comments") or {}).get("nodes") or []:
            if not comment:
                continue
            login = ((comment.get("author") or {}).get("login")) or ""
            if login and login != author:
                items.append((comment.get("createdAt") or "", login))
    items.sort()
    return items


def _last_change_request(node, by=None):
    """Return the timestamp and author of the most recent change request.

    With `by` set, only that reviewer's own change requests count: the board wants to know
    whether the pull request moved after *my* review, not after somebody else's.
    """
    last_at, last_by = "", ""
    for review in (node.get("reviews") or {}).get("nodes") or []:
        if not review or review.get("state") != "CHANGES_REQUESTED":
            continue
        login = ((review.get("author") or {}).get("login")) or ""
        if by and login != by:
            continue
        at = review.get("submittedAt") or ""
        if at >= last_at:
            last_at, last_by = at, login
    return last_at, last_by


def _my_review(node, login):
    """Return the state and timestamp of my own latest blocking review.

    `COMMENTED` reviews are skipped the way GitHub skips them when it computes `reviewDecision`:
    a comment neither approves nor blocks, so it must not hide an earlier change request.
    """
    last_at, last_state = "", ""
    if not login:
        return last_state, last_at
    for review in (node.get("reviews") or {}).get("nodes") or []:
        if not review:
            continue
        state = review.get("state") or ""
        if state not in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            continue
        if ((review.get("author") or {}).get("login")) != login:
            continue
        at = review.get("submittedAt") or ""
        if at >= last_at:
            last_at, last_state = at, state
    return last_state, last_at


def _epoch(at):
    """Seconds since the epoch for a GitHub ISO timestamp, or 0 when it cannot be read."""
    try:
        return calendar.timegm(time.strptime(at, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return 0


def _pushes(node):
    """Commit dates folded into push events.

    Commits arriving within [PUSH_GAP_SECONDS] of each other are one event: the board shows
    how many times the branch moved, not how many commits it holds.
    """
    dates = []
    for item in (node.get("commits") or {}).get("nodes") or []:
        at = (((item or {}).get("commit") or {}).get("committedDate")) or ""
        if at:
            dates.append(at)
    dates.sort()
    events = []
    for at in dates:
        if events and _epoch(at) - _epoch(events[-1]["last"]) <= PUSH_GAP_SECONDS:
            events[-1]["n"] += 1
            events[-1]["last"] = at
            continue
        events.append({"k": "push", "at": at, "by": "", "n": 1, "last": at})
    for event in events:
        event.pop("last", None)
    return events


def _timeline(node):
    """Everything that happened on a pull request, oldest first, as flat events.

    One event is one act: a review verdict, somebody's comment, a push. Runs of the same kind
    collapse into a single event with a count, so a thread of five replies reads as one step of
    the timeline instead of five. Pushes never collapse with each other — two pushes in a row
    are exactly what the row should show.
    """
    events = []
    echoes = []
    commented = []
    for review in (node.get("reviews") or {}).get("nodes") or []:
        if not review:
            continue
        at = review.get("submittedAt") or ""
        login = ((review.get("author") or {}).get("login")) or ""
        kind = {
            "APPROVED": "approve",
            "CHANGES_REQUESTED": "cr",
            "DISMISSED": "dismissed",
        }.get(review.get("state") or "")
        if kind:
            events.append({"k": kind, "at": at, "by": login, "n": 1})
        elif review.get("state") == "COMMENTED":
            commented.append({"k": "comment", "at": at, "by": login, "n": 1})
    for comment in ((node.get("comments") or {}).get("nodes") or []):
        if not comment:
            continue
        events.append({
            "k": "comment",
            "at": comment.get("createdAt") or "",
            "by": ((comment.get("author") or {}).get("login")) or "",
            "n": 1,
        })
    for thread in (node.get("reviewThreads") or {}).get("nodes") or []:
        for comment in ((thread or {}).get("comments") or {}).get("nodes") or []:
            if not comment:
                continue
            at = comment.get("createdAt") or ""
            login = ((comment.get("author") or {}).get("login")) or ""
            events.append({"k": "comment", "at": at, "by": login, "n": 1})
            echoes.append((login, _epoch(at)))
    for review in commented:
        moment = _epoch(review["at"])
        if any(login == review["by"] and abs(moment - at) <= REVIEW_ECHO_SECONDS
               for login, at in echoes):
            continue
        events.append(review)
    events.extend(_pushes(node))
    events.sort(key=lambda event: (event["at"], event["k"]))

    merged = []
    for event in events:
        last = merged[-1] if merged else None
        if last and last["k"] == event["k"] and event["k"] != "push":
            last["n"] += event["n"]
            last["at"] = event["at"]
            if event["by"] and event["by"] not in last["who"]:
                last["who"].append(event["by"])
            continue
        merged.append({**event, "who": [event["by"]] if event["by"] else []})
    for event in merged:
        event["by"] = ", ".join(event.pop("who")) or event.get("by") or ""
    return merged


def _row(node, viewer):
    """Flatten one GraphQL pull request node into the shape the app renders."""
    author = ((node.get("author") or {}).get("login")) or ""
    decision = node.get("reviewDecision") or "NONE"
    title = node.get("title") or ""
    key = task_key(title)
    comments = _discussion(node, author)
    cr_at, cr_by = _last_change_request(node)
    after_cr = [item for item in comments if cr_at and item[0] > cr_at]
    commits = (node.get("commits") or {}).get("nodes") or []
    pushed_at = (((commits[-1] or {}).get("commit") or {}).get("committedDate")) if commits else ""
    after_push = [item for item in comments if pushed_at and item[0] > pushed_at]
    my_state, my_review_at = _my_review(node, viewer)
    my_cr_at = my_review_at if my_state == "CHANGES_REQUESTED" else ""
    pushed_after_my_cr = bool(my_cr_at and pushed_at and pushed_at > my_cr_at)

    def logins(items):
        seen = []
        for _, login in items:
            if login not in seen:
                seen.append(login)
        return seen

    return {
        "repo": (node.get("repository") or {}).get("name") or "",
        "number": node.get("number"),
        "title": title,
        "url": node.get("url") or "",
        "task": key,
        "task_url": (JIRA_BROWSE + key) if key else "",
        "author": author,
        "mine": bool(viewer) and author == viewer,
        "draft": bool(node.get("isDraft")),
        "review_decision": decision,
        "approvals": (node.get("approvals") or {}).get("totalCount") or 0,
        "change_requests": (node.get("changeRequests") or {}).get("totalCount") or 0,
        "changes_requested_at": cr_at,
        "changes_requested_by": cr_by,
        "my_review": my_state,
        "my_change_request_at": my_cr_at,
        "pushed_after_my_cr": pushed_after_my_cr,
        "comments_total": node.get("totalCommentsCount") or 0,
        "comments_recent": len(comments),
        "comments_after_cr": len(after_cr),
        "comments_after_cr_by": logins(after_cr),
        "comments_after_push": len(after_push),
        "comments_after_push_by": logins(after_push),
        "comments_truncated": len(comments) >= RECENT_COMMENTS + RECENT_THREADS * THREAD_REPLIES,
        "pushed_at": pushed_at or "",
        "timeline": _timeline(node),
        "created_at": node.get("createdAt"),
        "updated_at": node.get("updatedAt"),
    }


def board(refresh=False):
    """Return the open pull requests of the configured repositories updated recently.

    Grouping, sorting and filtering (task, repository, author, review state, drafts) belong to
    the client: one shared snapshot keeps the GitHub rate limit low and makes switching a
    filter free.
    """
    now = time.time()
    with _CACHE_LOCK:
        cached = _CACHE["value"]
        if not refresh and cached is not None and now - _CACHE["at"] < CACHE_SECONDS:
            return cached
    try:
        config = load_config()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {"ok": False, "msg": str(exc), "pulls": []}
    if not config["repos"]:
        return {"ok": True, "owner": config["owner"], "repos": [], "pulls": [],
                "viewer": "", "updated_at": int(now)}

    since = time.strftime("%Y-%m-%d", time.gmtime(now - FRESH_DAYS * 86400))
    search = "is:pr is:open sort:updated-desc updated:>=%s " % since + " ".join(
        "repo:%s/%s" % (config["owner"], repo) for repo in config["repos"]
    )
    rows = []
    viewer = ""
    cursor = None
    try:
        for _ in range(MAX_PAGES):
            data = _graphql({"q": search, "size": PAGE_SIZE, "cursor": cursor})
            viewer = ((data.get("viewer") or {}).get("login")) or viewer
            result = data.get("search") or {}
            for node in result.get("nodes") or []:
                if node:
                    rows.append(_row(node, viewer))
            page = result.get("pageInfo") or {}
            if not page.get("hasNextPage"):
                break
            cursor = page.get("endCursor")
    except RuntimeError as exc:
        return {"ok": False, "msg": str(exc), "owner": config["owner"],
                "repos": config["repos"], "pulls": [], "viewer": viewer,
                "updated_at": int(now)}

    rows.sort(key=lambda row: (row["repo"], -(row["number"] or 0)))
    result = {
        "ok": True,
        "owner": config["owner"],
        "repos": config["repos"],
        "viewer": viewer,
        "pulls": rows,
        "count": len(rows),
        "tasks": sorted({row["task"] for row in rows if row["task"]}),
        "updated_at": int(now),
        "since": since,
        "fresh_days": FRESH_DAYS,
        "config_path": os.path.basename(CONFIG_PATH),
    }
    with _CACHE_LOCK:
        _CACHE.update({"at": now, "value": result})
    return result
