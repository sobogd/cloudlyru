"""File-backed pull request board for the Mac status server."""

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
CACHE_SECONDS = 60
PAGE_SIZE = 100
MAX_PAGES = 5

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
        author { login }
        repository { name }
        reviewDecision
        changesRequested: reviews(states: CHANGES_REQUESTED) { totalCount }
        approvals: reviews(states: APPROVED) { totalCount }
        comments { totalCount }
      }
    }
  }
}
"""


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
        with urllib.request.urlopen(request, timeout=25) as response:
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


def _row(node, viewer):
    """Flatten one GraphQL pull request node into the shape the app renders."""
    author = ((node.get("author") or {}).get("login")) or ""
    decision = node.get("reviewDecision") or "NONE"
    return {
        "repo": (node.get("repository") or {}).get("name") or "",
        "number": node.get("number"),
        "title": node.get("title") or "",
        "url": node.get("url") or "",
        "author": author,
        "mine": bool(viewer) and author == viewer,
        "draft": bool(node.get("isDraft")),
        "review_decision": decision,
        "changes_requested": (node.get("changesRequested") or {}).get("totalCount") or 0,
        "approvals": (node.get("approvals") or {}).get("totalCount") or 0,
        "comments": (node.get("comments") or {}).get("totalCount") or 0,
        "created_at": node.get("createdAt"),
        "updated_at": node.get("updatedAt"),
    }


def board(refresh=False):
    """Return every open pull request of the configured repositories, unfiltered.

    Filtering (mine, drafts, review state, repository) belongs to the client: the board is
    cheap to filter locally and one shared snapshot keeps the GitHub rate limit low.
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

    search = "is:pr is:open sort:updated-desc " + " ".join(
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
        "updated_at": int(now),
        "config_path": os.path.basename(CONFIG_PATH),
    }
    with _CACHE_LOCK:
        _CACHE.update({"at": now, "value": result})
    return result
