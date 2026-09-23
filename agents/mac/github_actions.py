"""File-backed GitHub Actions dashboard for the Mac status server."""

import calendar
import concurrent.futures
import json
import os
import re
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("MAC_STATUS_GITHUB_ACTIONS_CONFIG") or os.path.join(
    BASE_DIR, "github-actions.json"
)
TOKEN_FILE = os.path.expanduser(
    os.environ.get("MAC_STATUS_GITHUB_TOKEN_FILE") or "~/work/.env"
)
TOKEN_KEY = os.environ.get("MAC_STATUS_GITHUB_TOKEN_KEY") or "GH_BSOKOLOV_TANGEM"
GITHUB_API = "https://api.github.com"
STATUS_CACHE_SECONDS = 30
AVERAGE_RUN_COUNT = 5

_CACHE_LOCK = threading.Lock()
_STATUS_CACHE = {"at": 0, "value": None}


def _validate_config(config):
    """Validate and normalize the JSON structure before API handlers use it."""
    if not isinstance(config, dict):
        raise ValueError("config must be an object")
    owner = str(config.get("owner") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", owner):
        raise ValueError("invalid owner")
    workflows = config.get("workflows")
    if not isinstance(workflows, list):
        raise ValueError("workflows must be an array")
    normalized = []
    seen = set()
    for item in workflows:
        if not isinstance(item, dict):
            raise ValueError("workflow must be an object")
        repo = str(item.get("repo") or "").strip()
        path = str(item.get("path") or "").strip()
        name = str(item.get("name") or path).strip()
        inputs = item.get("inputs") or {}
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", repo):
            raise ValueError("invalid repository name")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+\.ya?ml", path):
            raise ValueError("workflow path must be a yml/yaml filename")
        if not isinstance(inputs, dict):
            raise ValueError("workflow inputs must be an object")
        key = (repo, path)
        if key in seen:
            raise ValueError("duplicate workflow: %s/%s" % key)
        seen.add(key)
        normalized.append({"repo": repo, "path": path, "name": name, "inputs": inputs})
    return {"owner": owner, "workflows": normalized}


def load_config():
    """Read the workflow list on every request so manual file edits take effect."""
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as handle:
            return _validate_config(json.load(handle))
    except FileNotFoundError:
        return {"owner": "tangem-developments", "workflows": []}


def _save_config(config):
    """Atomically replace the config to prevent partial writes on interruption."""
    config = _validate_config(config)
    directory = os.path.dirname(CONFIG_PATH)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".github-actions-", suffix=".json", dir=directory
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
        _STATUS_CACHE.update({"at": 0, "value": None})
    return config


def edit_config(data):
    """Add or remove one workflow and persist the adjacent JSON config."""
    try:
        config = load_config()
        op = str(data.get("op") or "")
        repo = str(data.get("repo") or "").strip()
        path = os.path.basename(str(data.get("path") or "").strip())
        if op == "remove":
            before = len(config["workflows"])
            config["workflows"] = [
                item
                for item in config["workflows"]
                if not (item["repo"] == repo and item["path"] == path)
            ]
            if len(config["workflows"]) == before:
                return {"ok": False, "msg": "workflow not found"}
        elif op == "add":
            inputs = data.get("inputs") or {}
            if not isinstance(inputs, dict):
                return {"ok": False, "msg": "inputs must be a JSON object"}
            item = {
                "repo": repo,
                "path": path,
                "name": str(data.get("name") or path).strip(),
                "inputs": inputs,
            }
            if any(
                old["repo"] == repo and old["path"] == path
                for old in config["workflows"]
            ):
                return {"ok": False, "msg": "workflow already exists"}
            config["workflows"].append(item)
            config["workflows"].sort(
                key=lambda workflow: (workflow["repo"], workflow["name"].lower())
            )
        else:
            return {"ok": False, "msg": "unknown config operation"}
        saved = _save_config(config)
        return {"ok": True, "msg": "saved", "count": len(saved["workflows"])}
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {"ok": False, "msg": str(exc)}


def _load_token():
    """Read only the work-token line without sourcing or exposing the env file."""
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key.strip() == TOKEN_KEY:
                    value = value.strip()
                    if (
                        len(value) >= 2
                        and value[0] == value[-1]
                        and value[0] in "\"'"
                    ):
                        value = value[1:-1]
                    return value
    except OSError:
        pass
    return ""


def _github(method, path, payload=None):
    """Call GitHub REST with the private work token and return decoded JSON."""
    token = _load_token()
    if not token:
        raise RuntimeError("work GitHub token is not configured")
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        GITHUB_API + path,
        data=body,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "User-Agent": "jevel-mac-status",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        message = ""
        try:
            message = json.loads(exc.read()).get("message", "")
        except Exception:
            pass
        detail = ": " + message if message else ""
        raise RuntimeError("GitHub API %s%s" % (exc.code, detail))
    except urllib.error.URLError as exc:
        raise RuntimeError("GitHub API unavailable: %s" % exc.reason)


def _duration(started, finished):
    """Convert two GitHub UTC timestamps into non-negative seconds."""
    try:
        start = calendar.timegm(time.strptime(started, "%Y-%m-%dT%H:%M:%SZ"))
        finish = calendar.timegm(time.strptime(finished, "%Y-%m-%dT%H:%M:%SZ"))
        return max(0, finish - start)
    except (TypeError, ValueError):
        return None


def _repo_runs(owner, repo):
    """Fetch recent repository runs used for state and duration aggregation."""
    path = "/repos/%s/%s/actions/runs?per_page=100" % (
        urllib.parse.quote(owner, safe=""),
        urllib.parse.quote(repo, safe=""),
    )
    return _github("GET", path).get("workflow_runs") or []


def dashboard(refresh=False):
    """Return workflows with latest status and a live five-run average."""
    now = time.time()
    with _CACHE_LOCK:
        cached = _STATUS_CACHE["value"]
        if (
            not refresh
            and cached is not None
            and now - _STATUS_CACHE["at"] < STATUS_CACHE_SECONDS
        ):
            return cached
    try:
        config = load_config()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {"ok": False, "msg": str(exc), "workflows": []}

    repos = sorted({item["repo"] for item in config["workflows"]})
    runs_by_repo = {}
    errors = {}
    # One repository-level request keeps a 100+ workflow refresh inexpensive.
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=min(6, max(1, len(repos)))
    ) as pool:
        futures = {
            pool.submit(_repo_runs, config["owner"], repo): repo for repo in repos
        }
        for future in concurrent.futures.as_completed(futures):
            repo = futures[future]
            try:
                runs_by_repo[repo] = future.result()
            except Exception as exc:
                errors[repo] = str(exc)
                runs_by_repo[repo] = []

    rows = []
    for item in config["workflows"]:
        expected_path = ".github/workflows/" + item["path"]
        matches = [
            run
            for run in runs_by_repo.get(item["repo"], [])
            if run.get("path") == expected_path
        ]
        latest = matches[0] if matches else None
        durations = []
        for run in matches:
            if run.get("status") == "completed" and run.get("conclusion") == "success":
                seconds = _duration(
                    run.get("run_started_at") or run.get("created_at"),
                    run.get("updated_at"),
                )
                if seconds is not None:
                    durations.append(seconds)
            if len(durations) >= AVERAGE_RUN_COUNT:
                break
        row = dict(item)
        row["average_seconds"] = (
            round(sum(durations) / len(durations)) if durations else None
        )
        row["average_samples"] = len(durations)
        row["latest"] = None if latest is None else {
            "id": latest.get("id"),
            "status": latest.get("status"),
            "conclusion": latest.get("conclusion"),
            "branch": latest.get("head_branch"),
            "event": latest.get("event"),
            "created_at": latest.get("created_at"),
            "updated_at": latest.get("updated_at"),
            "url": latest.get("html_url"),
        }
        rows.append(row)

    result = {
        "ok": not errors,
        "owner": config["owner"],
        "workflows": rows,
        "errors": errors,
        "updated_at": int(now),
        "average_run_count": AVERAGE_RUN_COUNT,
        "config_path": os.path.basename(CONFIG_PATH),
    }
    with _CACHE_LOCK:
        _STATUS_CACHE.update({"at": now, "value": result})
    return result


def refs(repo):
    """Return selectable branches and tags for a configured repository."""
    try:
        config = load_config()
        if repo not in {item["repo"] for item in config["workflows"]}:
            return {"ok": False, "msg": "repository is not configured"}
        owner = urllib.parse.quote(config["owner"], safe="")
        encoded_repo = urllib.parse.quote(repo, safe="")
        branches = _github(
            "GET", "/repos/%s/%s/branches?per_page=100" % (owner, encoded_repo)
        )
        tags = _github(
            "GET", "/repos/%s/%s/tags?per_page=100" % (owner, encoded_repo)
        )
        return {
            "ok": True,
            "branches": [item.get("name") for item in branches if item.get("name")],
            "tags": [item.get("name") for item in tags if item.get("name")],
        }
    except Exception as exc:
        return {"ok": False, "msg": str(exc)}


def _configured_workflow(config, repo, path):
    """Resolve an allowed workflow so arbitrary repository dispatch is blocked."""
    return next(
        (
            item
            for item in config["workflows"]
            if item["repo"] == repo and item["path"] == path
        ),
        None,
    )


def dispatch(data):
    """Dispatch one configured workflow after validating ref and inputs."""
    try:
        config = load_config()
        repo = str(data.get("repo") or "").strip()
        path = os.path.basename(str(data.get("path") or "").strip())
        ref = str(data.get("ref") or "").strip()
        inputs = data.get("inputs") or {}
        item = _configured_workflow(config, repo, path)
        if not item:
            return {"ok": False, "msg": "workflow is not configured"}
        if not ref:
            return {"ok": False, "msg": "branch or tag is required"}
        if not isinstance(inputs, dict):
            return {"ok": False, "msg": "inputs must be an object"}

        clean_inputs = {}
        for key, spec in item["inputs"].items():
            value = inputs.get(key, spec.get("default"))
            if spec.get("required") and (value is None or value == ""):
                return {"ok": False, "msg": "missing input: " + key}
            if value is None:
                continue
            if spec.get("type") == "boolean":
                value = value is True or str(value).lower() == "true"
            elif spec.get("options") and value not in spec["options"]:
                return {"ok": False, "msg": "invalid value for " + key}
            clean_inputs[key] = value
        endpoint = "/repos/%s/%s/actions/workflows/%s/dispatches" % (
            urllib.parse.quote(config["owner"], safe=""),
            urllib.parse.quote(repo, safe=""),
            urllib.parse.quote(path, safe=""),
        )
        _github("POST", endpoint, {"ref": ref, "inputs": clean_inputs})
        with _CACHE_LOCK:
            _STATUS_CACHE.update({"at": 0, "value": None})
        return {"ok": True, "msg": "workflow dispatched"}
    except Exception as exc:
        return {"ok": False, "msg": str(exc)}


def rerun(data):
    """Re-run a known run while restricting it to configured repositories."""
    try:
        config = load_config()
        repo = str(data.get("repo") or "").strip()
        run_id = int(data.get("run_id") or 0)
        if (
            repo not in {item["repo"] for item in config["workflows"]}
            or run_id <= 0
        ):
            return {"ok": False, "msg": "invalid rerun target"}
        endpoint = "/repos/%s/%s/actions/runs/%s/rerun" % (
            urllib.parse.quote(config["owner"], safe=""),
            urllib.parse.quote(repo, safe=""),
            run_id,
        )
        _github("POST", endpoint, {})
        with _CACHE_LOCK:
            _STATUS_CACHE.update({"at": 0, "value": None})
        return {"ok": True, "msg": "rerun requested"}
    except Exception as exc:
        return {"ok": False, "msg": str(exc)}


# The page stays dependency-free like the parent status server. Repository refs
# are loaded only when a workflow is expanded, avoiding unnecessary API calls.
ACTIONS_PAGE = r'''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GitHub Actions</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{font-family:ui-monospace,Menlo,monospace;background:#0d1117;color:#e6edf3;margin:0 auto;padding:18px;max-width:1180px}a{color:#58a6ff}h1{font-size:20px;margin:12px 0 4px}.muted{color:#8b949e;font-size:11px}.toolbar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:14px 0}button,input,select,textarea{font:12px ui-monospace,Menlo,monospace;background:#0d1117;color:#e6edf3;border:1px solid #30363d;border-radius:6px;padding:7px}button{background:#21262d;cursor:pointer}button:hover{border-color:#58a6ff}button.danger{color:#f85149;border-color:#6e3030}.repo{background:#161b22;border:1px solid #30363d;border-radius:10px;margin:12px 0;overflow:hidden}.repo h2{font-size:14px;margin:0;padding:12px;border-bottom:1px solid #30363d}.wf{padding:10px 12px;border-top:1px solid #21262d}.wf:first-of-type{border-top:0}.head{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.name{font-weight:700;flex:1;min-width:220px}.pill{border:1px solid #30363d;border-radius:999px;padding:2px 7px;font-size:10px}.ok{color:#3fb950}.bad{color:#f85149}.warn{color:#d29922}.runbox{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px;margin-top:8px;padding:10px;background:#0d1117;border-radius:7px}.field label{display:block;color:#8b949e;font-size:10px;margin-bottom:3px}.field input,.field select{width:100%}.actions{grid-column:1/-1;display:flex;gap:6px;align-items:center;flex-wrap:wrap}.msg{font-size:11px;color:#8b949e}.add{display:none;background:#161b22;border:1px solid #30363d;border-radius:9px;padding:12px;margin-bottom:12px}.add.show{display:block}.addgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px}.add textarea{width:100%;height:80px;margin-top:8px}.summary{font-size:12px;color:#8b949e}.dot{width:9px;height:9px;border-radius:50%;background:#6e7681}.dot.ok{background:#3fb950}.dot.bad{background:#f85149}.dot.warn{background:#d29922}@media(max-width:520px){body{padding:10px}.name{min-width:160px}}
</style></head><body>
<a href="/">← status</a><h1>GitHub Actions</h1>
<div class="muted">Configuration is stored in <code>github-actions.json</code>. Average duration is recalculated from the latest successful runs.</div>
<div class="toolbar"><button onclick="load(true)">refresh now</button><button onclick="toggleAdd()">add workflow</button><span id="summary" class="summary">loading…</span></div>
<div id="add" class="add"><div class="addgrid"><input id="arepo" placeholder="repository"><input id="apath" placeholder="workflow.yml"><input id="aname" placeholder="display name"></div><textarea id="ainputs" placeholder='inputs JSON, for example {"ENVIRONMENT":{"type":"choice","required":true,"options":["dev","prod"]}}'>{}</textarea><div><button onclick="addWorkflow()">save workflow</button> <span id="addmsg" class="msg"></span></div></div>
<div id="repos"></div><script>
const $=id=>document.getElementById(id);let model=null;const refsCache={};
function esc(v){return String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function duration(s){if(s==null)return '—';s=Math.round(s);const m=Math.floor(s/60),r=s%60;return m?m+'m '+r+'s':r+'s';}
function state(run){if(!run)return ['','never'];if(run.status!=='completed')return ['warn',run.status];return [run.conclusion==='success'?'ok':run.conclusion==='failure'?'bad':'warn',run.conclusion||run.status];}
async function api(url,opt){const r=await fetch(url,opt);const d=await r.json();if(!d.ok&&d.msg)throw new Error(d.msg);return d;}
async function load(force){$('summary').textContent='refreshing…';try{model=await api('/api/github-actions'+(force?'?refresh=1':''));render();$('summary').textContent=model.workflows.length+' workflows · updated '+new Date(model.updated_at*1000).toLocaleTimeString()+(Object.keys(model.errors||{}).length?' · some repositories failed':'');}catch(e){$('summary').textContent=e.message;}}
function render(){const grouped={};for(const w of model.workflows)(grouped[w.repo]??=[]).push(w);$('repos').innerHTML=Object.entries(grouped).map(([repo,items])=>'<section class="repo"><h2>'+esc(repo)+' <span class="muted">'+items.length+'</span></h2>'+items.map(w=>row(w)).join('')+'</section>').join('');}
function row(w){const [cls,label]=state(w.latest),id=btoa(unescape(encodeURIComponent(w.repo+'/'+w.path))).replace(/=/g,'');const inputs=Object.entries(w.inputs||{}).map(([k,s])=>field(id,k,s)).join('');const last=w.latest?'<a target="_blank" href="'+esc(w.latest.url)+'">#'+w.latest.id+'</a> · '+esc(w.latest.branch||''):'no runs in recent history';return '<div class="wf"><div class="head"><span class="dot '+cls+'"></span><span class="name">'+esc(w.name)+'<br><span class="muted">'+esc(w.path)+'</span></span><span class="pill '+cls+'">'+esc(label)+'</span><span class="pill">avg '+duration(w.average_seconds)+' · '+w.average_samples+'/5</span></div><div class="muted" style="margin:4px 0 0 19px">'+last+'</div><details data-repo="'+esc(w.repo)+'" ontoggle="loadRefs(this,\''+id+'\')"><summary class="muted" style="cursor:pointer;margin:7px 0 0 19px">run / parameters</summary><div class="runbox"><div class="field"><label>branch or tag</label><input id="ref-'+id+'" list="refs-'+id+'" value="main"><datalist id="refs-'+id+'"></datalist></div>'+inputs+'<div class="actions"><button onclick="dispatch(\''+esc(w.repo)+'\',\''+esc(w.path)+'\',\''+id+'\')">run</button>'+(w.latest?'<button onclick="rerun(\''+esc(w.repo)+'\','+w.latest.id+',\''+id+'\')">rerun latest</button>':'')+'<button class="danger" onclick="removeWorkflow(\''+esc(w.repo)+'\',\''+esc(w.path)+'\')">remove</button><span id="msg-'+id+'" class="msg"></span></div></div></details></div>';}
function field(id,key,s){const label='<label>'+esc(key)+(s.required?' *':'')+'</label>';if(s.type==='choice')return '<div class="field">'+label+'<select data-input="'+esc(key)+'" data-id="'+id+'">'+(s.options||[]).map(v=>'<option '+(v===s.default?'selected':'')+'>'+esc(v)+'</option>').join('')+'</select></div>';if(s.type==='boolean')return '<div class="field">'+label+'<select data-input="'+esc(key)+'" data-id="'+id+'"><option value="true" '+(s.default===true?'selected':'')+'>true</option><option value="false" '+(s.default===false?'selected':'')+'>false</option></select></div>';return '<div class="field">'+label+'<input data-input="'+esc(key)+'" data-id="'+id+'" value="'+esc(s.default??'')+'"></div>';}
async function loadRefs(details,id){if(!details.open)return;const repo=details.dataset.repo;if(!refsCache[repo]){try{refsCache[repo]=await api('/api/github-actions/refs?repo='+encodeURIComponent(repo));}catch(e){$('msg-'+id).textContent=e.message;return;}}const d=refsCache[repo];$('refs-'+id).innerHTML=d.branches.map(v=>'<option value="'+esc(v)+'">branch</option>').join('')+d.tags.map(v=>'<option value="'+esc(v)+'">tag</option>').join('');}
async function dispatch(repo,path,id){const msg=$('msg-'+id);msg.textContent='starting…';const inputs={};document.querySelectorAll('[data-id="'+id+'"]').forEach(el=>inputs[el.dataset.input]=el.value);try{const d=await api('/api/github-actions/run',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({repo,path,ref:$('ref-'+id).value,inputs})});msg.textContent=d.msg;setTimeout(()=>load(true),2500);}catch(e){msg.textContent=e.message;}}
async function rerun(repo,run_id,id){const msg=$('msg-'+id);msg.textContent='requesting rerun…';try{const d=await api('/api/github-actions/rerun',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({repo,run_id})});msg.textContent=d.msg;setTimeout(()=>load(true),2500);}catch(e){msg.textContent=e.message;}}
function toggleAdd(){$('add').classList.toggle('show');}
async function addWorkflow(){let inputs;try{inputs=JSON.parse($('ainputs').value||'{}');}catch(e){$('addmsg').textContent='invalid inputs JSON';return;}try{const d=await api('/api/github-actions/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({op:'add',repo:$('arepo').value,path:$('apath').value,name:$('aname').value,inputs})});$('addmsg').textContent=d.msg;await load(true);}catch(e){$('addmsg').textContent=e.message;}}
async function removeWorkflow(repo,path){if(!confirm('Remove '+repo+'/'+path+' from the local list?'))return;try{await api('/api/github-actions/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({op:'remove',repo,path})});await load(true);}catch(e){alert(e.message);}}
load(true);setInterval(()=>load(false),30000);
</script></body></html>'''
