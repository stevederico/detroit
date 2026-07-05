#!/usr/bin/env python3
"""detroit web — a local dashboard for the code factory.

Monitors the factory floor (task queue, live agent status, logs, PRs) and lets
you control it (create a task, trigger a run, approve a plan at the gate).
Reads/writes the same files factory.sh uses — no database, no deps (stdlib only).

    python3 web.py            # http://127.0.0.1:4600
    DETROIT_UI_PORT=8080 python3 web.py

Local only by design: binds 127.0.0.1 and can run factory.sh, so never expose it.
"""

import glob
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
TASK_DIR = os.path.join(ROOT, "tasks")
DONE_DIR = os.path.join(TASK_DIR, "done")
LOG_DIR = os.path.join(ROOT, "logs")
STATUS_DIR = os.path.join(ROOT, ".status")
PORT = int(os.environ.get("DETROIT_UI_PORT", "4600"))
SLUG_RE = re.compile(r"[^a-z0-9-]+")
PR_RE = re.compile(r"https://github\.com/[^\s]*pull/\d+")


def _read(path, limit=None):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()[:limit] if limit else f.read()
    except OSError:
        return ""


def _preview(md):
    # First non-frontmatter, non-blank line of a task file.
    lines, in_fm = md.splitlines(), False
    for i, ln in enumerate(lines):
        if i == 0 and ln.strip() == "---":
            in_fm = True
            continue
        if in_fm:
            if ln.strip() == "---":
                in_fm = False
            continue
        if ln.strip():
            return ln.strip()[:140]
    return ""


def _repo_of(md):
    m = re.search(r"^repo:\s*(\S+)", md, re.MULTILINE)
    return m.group(1) if m else ""


def state():
    pending = []
    for p in sorted(glob.glob(os.path.join(TASK_DIR, "*.md"))):
        md = _read(p)
        pending.append({"name": os.path.basename(p)[:-3], "repo": _repo_of(md), "preview": _preview(md)})
    done = sorted(os.path.basename(p)[:-3] for p in glob.glob(os.path.join(DONE_DIR, "*.md")))

    agents = []
    for p in sorted(glob.glob(os.path.join(STATUS_DIR, "agent-*"))):
        agents.append({"id": os.path.basename(p).split("-", 1)[1], "status": _read(p).strip()})

    awaiting = []
    for p in sorted(glob.glob(os.path.join(STATUS_DIR, "approve-request-*"))):
        aid = os.path.basename(p).rsplit("-", 1)[1]
        awaiting.append({"id": aid, "plan": _read(_read(p).strip(), 4000).strip()})

    logs = sorted(glob.glob(os.path.join(LOG_DIR, "*.log")), reverse=True)
    tail, prs = "", []
    if logs:
        tail = "\n".join(_read(logs[0]).splitlines()[-120:])
    for lp in logs[:20]:
        prs += PR_RE.findall(_read(lp))
    prs = list(dict.fromkeys(prs))  # de-dupe, keep order

    return {
        "pending": pending,
        "done": done,
        "agents": agents,
        "awaiting": awaiting,
        "log": tail,
        "logfile": os.path.basename(logs[0]) if logs else "",
        "prs": prs[:30],
    }


def create_task(name, repo, body):
    slug = SLUG_RE.sub("-", (name or "task").lower().strip()).strip("-") or "task"
    path = os.path.join(TASK_DIR, slug + ".md")
    n = 1
    while os.path.exists(path):
        path = os.path.join(TASK_DIR, f"{slug}-{n}.md")
        n += 1
    os.makedirs(TASK_DIR, exist_ok=True)
    fm = f"---\nrepo: {repo}\n---\n\n" if repo.strip() else ""
    with open(path, "w", encoding="utf-8") as f:
        f.write(fm + (body or "").strip() + "\n")
    return os.path.basename(path)


def trigger_run(parallel):
    cmd = ["bash", "factory.sh"]
    if parallel and str(parallel).isdigit() and int(parallel) > 1:
        cmd += ["--parallel", str(int(parallel))]
    env = dict(os.environ, DETROIT_APPROVE_PLAN=os.environ.get("DETROIT_APPROVE_PLAN", "web"))
    subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True, env=env)


def approve(agent_id, decision):
    if not re.fullmatch(r"\d+", str(agent_id)):
        return
    with open(os.path.join(STATUS_DIR, f"approve-{agent_id}"), "w", encoding="utf-8") as f:
        f.write("y" if decision == "approve" else "n")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass  # quiet

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif self.path.startswith("/api/state"):
            self._send(200, json.dumps(state()))
        else:
            self._send(404, "{}")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or "{}")
        except json.JSONDecodeError:
            return self._send(400, '{"error":"bad json"}')
        if self.path == "/api/task":
            name = create_task(payload.get("name", ""), payload.get("repo", ""), payload.get("body", ""))
            self._send(200, json.dumps({"created": name}))
        elif self.path == "/api/run":
            trigger_run(payload.get("parallel"))
            self._send(200, '{"started":true}')
        elif self.path == "/api/approve":
            approve(payload.get("id", ""), payload.get("decision", ""))
            self._send(200, '{"ok":true}')
        else:
            self._send(404, "{}")


PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>detroit — factory floor</title>
<style>
:root{--bg:#0e1116;--panel:#161b22;--line:#232a33;--ink:#e6edf3;--mut:#8b98a5;--acc:#f2a900;--ok:#2ea043;--bad:#e5534b;--run:#3a6ea5}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
header{display:flex;align-items:center;gap:12px;padding:14px 20px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:5}
header h1{font-size:16px;margin:0;letter-spacing:.5px}header .badge{background:var(--acc);color:#3a2a00;font-weight:700;padding:2px 8px;border-radius:5px;font-size:11px;letter-spacing:.1em}
header .pill{margin-left:auto;color:var(--mut);font-size:12px}
main{display:grid;grid-template-columns:1.1fr 1fr 1.4fr;gap:14px;padding:16px;align-items:start}
@media(max-width:900px){main{grid-template-columns:1fr}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
.card>h2{margin:0;padding:10px 14px;font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--mut);border-bottom:1px solid var(--line);display:flex;justify-content:space-between}
.card .body{padding:12px 14px;display:flex;flex-direction:column;gap:10px}
.item{border:1px solid var(--line);border-radius:8px;padding:9px 11px;background:#0f141b}
.item .n{font-weight:600}.item .m{color:var(--mut);font-size:12px}.tag{font-size:10px;color:var(--acc);border:1px solid var(--line);border-radius:4px;padding:1px 6px;margin-left:6px}
.agent{display:flex;align-items:center;gap:9px}.dot{width:9px;height:9px;border-radius:50%;background:var(--run);flex:none;box-shadow:0 0 8px var(--run)}
.agent.done .dot{background:var(--ok);box-shadow:0 0 8px var(--ok)}.agent.fail .dot{background:var(--bad);box-shadow:0 0 8px var(--bad)}.agent.idle .dot{background:var(--mut);box-shadow:none}
pre.log{margin:0;padding:12px 14px;background:#0b0e13;max-height:60vh;overflow:auto;font-size:12px;color:#c9d4de;white-space:pre-wrap;word-break:break-word}
.done-list{display:flex;flex-wrap:wrap;gap:6px}.done-list span{font-size:11px;color:var(--mut);border:1px solid var(--line);border-radius:4px;padding:2px 7px}
a{color:var(--acc)}a.pr{display:block;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
button{font:inherit;background:var(--acc);color:#3a2a00;border:0;border-radius:6px;padding:7px 12px;font-weight:700;cursor:pointer}
button.ghost{background:transparent;color:var(--ink);border:1px solid var(--line)}button.bad{background:var(--bad);color:#fff}button.ok{background:var(--ok);color:#fff}
input,textarea{width:100%;background:#0b0e13;border:1px solid var(--line);border-radius:6px;color:var(--ink);padding:8px;font:inherit}
textarea{min-height:70px;resize:vertical}.row{display:flex;gap:8px}.row>*{flex:1}
.approve{border:1px solid var(--acc);border-radius:8px;padding:10px;background:#1a1408}.approve .m{max-height:120px;overflow:auto;white-space:pre-wrap;font-size:11px;color:var(--mut);margin:6px 0}
.empty{color:var(--mut);font-size:12px;font-style:italic}
</style></head><body>
<header><span class="badge">DETROIT</span><h1>factory floor</h1><span class="pill" id="pill">connecting…</span></header>
<main>
  <section class="card">
    <h2>Queue <span id="qc"></span></h2>
    <div class="body">
      <div id="awaiting"></div>
      <div id="queue"><span class="empty">no pending tasks</span></div>
      <details><summary style="cursor:pointer;color:var(--mut);font-size:12px">+ new task</summary>
        <div class="body" style="padding:10px 0 0">
          <input id="t-name" placeholder="task name (e.g. add-dark-mode)">
          <input id="t-repo" placeholder="repo (optional — blank = new repo)">
          <textarea id="t-body" placeholder="What should the agent build?"></textarea>
          <div class="row"><button onclick="addTask()">Add task</button><div style="flex:2"></div></div>
        </div>
      </details>
      <div class="row"><button onclick="run(1)">▶ Run one</button><button class="ghost" onclick="run(3)">▶ Run ×3</button></div>
    </div>
  </section>
  <section class="card">
    <h2>Agents</h2>
    <div class="body" id="agents"><span class="empty">idle</span></div>
    <h2 style="border-top:1px solid var(--line)">Done <span id="dc"></span></h2>
    <div class="body"><div class="done-list" id="done"><span class="empty">nothing shipped yet</span></div></div>
    <h2 style="border-top:1px solid var(--line)">Pull requests</h2>
    <div class="body" id="prs"><span class="empty">none</span></div>
  </section>
  <section class="card">
    <h2>Log <span id="lf" class="m"></span></h2>
    <pre class="log" id="log">—</pre>
  </section>
</main>
<script>
const $=s=>document.querySelector(s), esc=t=>(t||"").replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
function cls(s){s=(s||'').toLowerCase();return s.includes('✓')||s.includes('done')?'done':s.includes('✗')||s.includes('fail')?'fail':s.includes('idle')?'idle':''}
async function post(u,b){await fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)})}
async function addTask(){const name=$('#t-name').value,repo=$('#t-repo').value,body=$('#t-body').value;
  if(!body.trim())return; await post('/api/task',{name,repo,body}); $('#t-name').value=$('#t-body').value='';tick()}
async function run(p){await post('/api/run',{parallel:p});tick()}
async function decide(id,d){await post('/api/approve',{id,decision:d});tick()}
let stuck=false;
async function tick(){
  try{const s=await(await fetch('/api/state')).json();stuck=false;$('#pill').textContent='live · '+new Date().toLocaleTimeString();
    $('#qc').textContent=s.pending.length||''; $('#dc').textContent=s.done.length||'';
    $('#queue').innerHTML=s.pending.length?s.pending.map(t=>`<div class="item"><div class="n">${esc(t.name)}${t.repo?`<span class="tag">${esc(t.repo)}</span>`:'<span class="tag">new repo</span>'}</div><div class="m">${esc(t.preview)}</div></div>`).join(''):'<span class="empty">no pending tasks</span>';
    $('#awaiting').innerHTML=s.awaiting.map(a=>`<div class="approve"><b>Plan ready · agent ${esc(a.id)}</b><div class="m">${esc(a.plan)}</div><div class="row"><button class="ok" onclick="decide('${esc(a.id)}','approve')">Approve</button><button class="bad" onclick="decide('${esc(a.id)}','reject')">Reject</button></div></div>`).join('');
    $('#agents').innerHTML=s.agents.length?s.agents.map(a=>`<div class="agent ${cls(a.status)}"><span class="dot"></span><div><div class="n">agent ${esc(a.id)}</div><div class="m">${esc(a.status)||'—'}</div></div></div>`).join(''):'<span class="empty">idle</span>';
    $('#done').innerHTML=s.done.length?s.done.map(d=>`<span>${esc(d)}</span>`).join(''):'<span class="empty">nothing shipped yet</span>';
    $('#prs').innerHTML=s.prs.length?s.prs.map(u=>`<a class="pr" href="${esc(u)}" target="_blank">${esc(u.replace('https://github.com/',''))}</a>`).join(''):'<span class="empty">none</span>';
    $('#lf').textContent=s.logfile; $('#log').textContent=s.log||'—'; const l=$('#log'); l.scrollTop=l.scrollHeight;
  }catch(e){if(!stuck){$('#pill').textContent='disconnected';stuck=true}}
}
tick();setInterval(tick,2000);
</script></body></html>"""


if __name__ == "__main__":
    os.makedirs(STATUS_DIR, exist_ok=True)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"detroit web → http://127.0.0.1:{PORT}  (Ctrl+C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
