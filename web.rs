// detroit web — a local dashboard for the code factory.
//
// Monitors the factory floor (task queue, live agent status, logs, PRs) and lets
// you control it (create a task, trigger a run, approve a plan at the gate).
// Reads/writes the same files factory.sh uses — no database, std-only (no crates).
//
//   rustc -O web.rs -o detroit-web && ./detroit-web    # http://127.0.0.1:4600
//   DETROIT_UI_PORT=8080 ./detroit-web
//
// Local only by design: binds 127.0.0.1 and can run factory.sh, so never expose it.

use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;

fn root() -> PathBuf {
    env::var("DETROIT_DIR").map(PathBuf::from).unwrap_or_else(|_| {
        env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
    })
}
fn status_dir() -> PathBuf { root().join(".status") }
fn task_dir() -> PathBuf { root().join("tasks") }
fn log_dir() -> PathBuf { root().join("logs") }

// Where the factory runs — same resolution as factory.sh: $DETROIT_PROJECTS,
// else the parent of the detroit repo. HOME collapsed to ~ for display.
fn projects() -> String {
    let p = env::var("DETROIT_PROJECTS").unwrap_or_else(|_| {
        root().parent().map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|| root().to_string_lossy().into_owned())
    });
    match env::var("HOME") {
        Ok(home) => p.strip_prefix(&home).map(|r| format!("~{r}")).unwrap_or(p),
        Err(_) => p,
    }
}

// ── helpers ──────────────────────────────────────────────
fn read(path: &PathBuf, limit: usize) -> String {
    match fs::read_to_string(path) {
        Ok(s) if limit > 0 && s.len() > limit => s[..limit].to_string(),
        Ok(s) => s,
        Err(_) => String::new(),
    }
}

fn jesc(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                let h = u8::from_str_radix(&s[i + 1..i + 3], 16);
                if let Ok(v) = h { out.push(v); i += 3; } else { out.push(b'%'); i += 1; }
            }
            b'+' => { out.push(b' '); i += 1; }
            c => { out.push(c); i += 1; }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn query(qs: &str, key: &str) -> String {
    for pair in qs.split('&') {
        let mut it = pair.splitn(2, '=');
        if it.next() == Some(key) {
            return url_decode(it.next().unwrap_or(""));
        }
    }
    String::new()
}

// First non-frontmatter, non-blank line of a task file.
fn preview(md: &str) -> String {
    let mut in_fm = false;
    for (i, ln) in md.lines().enumerate() {
        let t = ln.trim();
        if i == 0 && t == "---" { in_fm = true; continue; }
        if in_fm { if t == "---" { in_fm = false; } continue; }
        if !t.is_empty() { return t.chars().take(140).collect(); }
    }
    String::new()
}

fn repo_of(md: &str) -> String {
    for ln in md.lines() {
        let t = ln.trim();
        if let Some(rest) = t.strip_prefix("repo:") {
            return rest.trim().to_string();
        }
    }
    String::new()
}

// Optional `labels:` frontmatter — comma-separated.
fn labels_of(md: &str) -> Vec<String> {
    for ln in md.lines() {
        let t = ln.trim();
        if let Some(rest) = t.strip_prefix("labels:") {
            return rest.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
        }
    }
    Vec::new()
}

fn md_stems(dir: &PathBuf) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(dir).into_iter().flatten().flatten()
        .filter(|e| e.path().is_file())
        .filter_map(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            n.strip_suffix(".md").map(|s| s.to_string())
        })
        .collect();
    v.sort();
    v
}

fn tail(s: &str, n: usize) -> String {
    let lines: Vec<&str> = s.lines().collect();
    let start = lines.len().saturating_sub(n);
    lines[start..].join("\n")
}

fn find_prs(text: &str, out: &mut Vec<String>) {
    let needle = "https://github.com/";
    let mut rest = text;
    while let Some(pos) = rest.find(needle) {
        let after = &rest[pos..];
        let end = after.find(|c: char| c.is_whitespace()).unwrap_or(after.len());
        let url = &after[..end];
        if url.contains("/pull/") && !out.contains(&url.to_string()) {
            out.push(url.to_string());
        }
        rest = &after[end.max(1)..];
    }
}

// ── state ────────────────────────────────────────────────
fn state_json() -> String {
    use std::collections::BTreeSet;

    // agents + awaiting (both live in .status). Collect agents first so task
    // status can be derived from what an agent is currently working on.
    let mut agents_vec: Vec<(String, String)> = Vec::new();
    let mut awaiting = String::new();
    if let Ok(rd) = fs::read_dir(status_dir()) {
        let mut entries: Vec<_> = rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        entries.sort();
        for name in &entries {
            if let Some(id) = name.strip_prefix("agent-") {
                agents_vec.push((id.to_string(), read(&status_dir().join(name), 0).trim().to_string()));
            } else if let Some(id) = name.strip_prefix("approve-request-") {
                let plan_path = PathBuf::from(read(&status_dir().join(name), 0).trim());
                let plan = read(&plan_path, 4000).trim().to_string();
                if !awaiting.is_empty() { awaiting.push(','); }
                awaiting.push_str(&format!("{{\"id\":{},\"plan\":{}}}", jesc(id), jesc(&plan)));
            }
        }
    }
    let agents = agents_vec.iter()
        .map(|(id, st)| format!("{{\"id\":{},\"status\":{}}}", jesc(id), jesc(st)))
        .collect::<Vec<_>>().join(",");

    // tasks: pending files + derived status + labels
    let mut labelset: BTreeSet<String> = BTreeSet::new();
    let mut tasks = String::new();
    let (mut queued, mut running, mut awaiting_n) = (0u32, 0u32, 0u32);
    for stem in md_stems(&task_dir()) {
        let md = read(&task_dir().join(format!("{stem}.md")), 0);
        let labels = labels_of(&md);
        for l in &labels { labelset.insert(l.clone()); }
        let mut status = "queued";
        for (_, st) in &agents_vec {
            if st.contains(&stem) { status = if st.contains("awaiting") { "awaiting" } else { "running" }; break; }
        }
        match status { "running" => running += 1, "awaiting" => awaiting_n += 1, _ => queued += 1 }
        if !tasks.is_empty() { tasks.push(','); }
        tasks.push_str(&format!("{{\"name\":{},\"repo\":{},\"preview\":{},\"labels\":[{}],\"status\":{}}}",
            jesc(&stem), jesc(&repo_of(&md)), jesc(&preview(&md)),
            labels.iter().map(|l| jesc(l)).collect::<Vec<_>>().join(","), jesc(status)));
    }
    let done: Vec<String> = md_stems(&task_dir().join("done"));
    let done_json = done.iter().map(|d| jesc(d)).collect::<Vec<_>>().join(",");
    let labels_json = labelset.iter().map(|l| jesc(l)).collect::<Vec<_>>().join(",");

    // logs + prs
    let mut logs: Vec<String> = fs::read_dir(log_dir()).into_iter().flatten().flatten()
        .filter_map(|e| { let n = e.file_name().to_string_lossy().into_owned();
            if n.ends_with(".log") { Some(n) } else { None } })
        .collect();
    logs.sort();
    logs.reverse();
    let logfile = logs.first().cloned().unwrap_or_default();
    let log = if logfile.is_empty() { String::new() } else { tail(&read(&log_dir().join(&logfile), 0), 120) };
    let mut prs = Vec::new();
    for lf in logs.iter().take(20) { find_prs(&read(&log_dir().join(lf), 0), &mut prs); }
    prs.truncate(30);
    let prs_json = prs.iter().map(|p| jesc(p)).collect::<Vec<_>>().join(",");

    format!("{{\"stats\":{{\"queued\":{queued},\"running\":{running},\"awaiting\":{awaiting_n},\"done\":{},\"prs\":{}}},\
\"labels\":[{labels_json}],\"tasks\":[{tasks}],\"done\":[{done_json}],\"agents\":[{agents}],\"awaiting\":[{awaiting}],\
\"log\":{},\"logfile\":{},\"projects\":{},\"prs\":[{prs_json}]}}",
        done.len(), prs.len(), jesc(&log), jesc(&logfile), jesc(&projects()))
}

// ── actions ──────────────────────────────────────────────
fn create_task(name: &str, repo: &str, labels: &str, body: &str) -> String {
    let mut slug: String = name.to_lowercase().chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' }).collect();
    while slug.contains("--") { slug = slug.replace("--", "-"); }
    let slug = slug.trim_matches('-').to_string();
    let slug = if slug.is_empty() { "task".to_string() } else { slug };
    let _ = fs::create_dir_all(task_dir());
    let mut path = task_dir().join(format!("{slug}.md"));
    let mut n = 1;
    while path.exists() { path = task_dir().join(format!("{slug}-{n}.md")); n += 1; }
    let mut fm = String::new();
    if !repo.trim().is_empty() || !labels.trim().is_empty() {
        fm.push_str("---\n");
        if !repo.trim().is_empty() { fm.push_str(&format!("repo: {}\n", repo.trim())); }
        if !labels.trim().is_empty() { fm.push_str(&format!("labels: {}\n", labels.trim())); }
        fm.push_str("---\n\n");
    }
    let _ = fs::write(&path, format!("{fm}{}\n", body.trim()));
    path.file_name().unwrap().to_string_lossy().into_owned()
}

fn trigger_run(parallel: &str) {
    let mut cmd = Command::new("bash");
    cmd.arg("factory.sh").current_dir(root())
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    if env::var("DETROIT_APPROVE_PLAN").is_err() { cmd.env("DETROIT_APPROVE_PLAN", "web"); }
    if let Ok(p) = parallel.parse::<u32>() { if p > 1 { cmd.arg("--parallel").arg(p.to_string()); } }
    let _ = cmd.spawn();
}

fn approve(id: &str, decision: &str) {
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) { return; }
    let verdict = if decision == "approve" { "y" } else { "n" };
    let _ = fs::write(status_dir().join(format!("approve-{id}")), verdict);
}

// ── http ─────────────────────────────────────────────────
fn send(stream: &mut TcpStream, code: &str, ctype: &str, body: &[u8]) {
    let head = format!(
        "HTTP/1.1 {code}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len());
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
}

fn handle(mut stream: TcpStream) {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    let mut header_end = 0;
    // read until end of headers
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&tmp[..n]);
                if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") { header_end = p + 4; break; }
                if buf.len() > 1 << 20 { break; }
            }
            Err(_) => return,
        }
    }
    if header_end == 0 { return; }
    let head = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let mut lines = head.lines();
    let req_line = lines.next().unwrap_or("");
    let mut parts = req_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let (path, qs) = match target.split_once('?') { Some((p, q)) => (p, q), None => (target, "") };

    let mut content_length = 0usize;
    for l in lines {
        if let Some(v) = l.to_ascii_lowercase().strip_prefix("content-length:") {
            content_length = v.trim().parse().unwrap_or(0);
        }
    }
    // read remaining body
    let mut body = buf[header_end..].to_vec();
    while body.len() < content_length {
        match stream.read(&mut tmp) { Ok(0) => break, Ok(n) => body.extend_from_slice(&tmp[..n]), Err(_) => break }
    }
    let body_str = String::from_utf8_lossy(&body).into_owned();

    match (method, path) {
        ("GET", "/") => send(&mut stream, "200 OK", "text/html; charset=utf-8", PAGE.as_bytes()),
        ("GET", "/api/state") => send(&mut stream, "200 OK", "application/json", state_json().as_bytes()),
        ("POST", "/api/task") => {
            let name = create_task(&query(qs, "name"), &query(qs, "repo"), &query(qs, "labels"), &body_str);
            send(&mut stream, "200 OK", "application/json", format!("{{\"created\":{}}}", jesc(&name)).as_bytes());
        }
        ("POST", "/api/run") => { trigger_run(&query(qs, "parallel")); send(&mut stream, "200 OK", "application/json", b"{\"started\":true}"); }
        ("POST", "/api/approve") => { approve(&query(qs, "id"), &query(qs, "decision")); send(&mut stream, "200 OK", "application/json", b"{\"ok\":true}"); }
        _ => send(&mut stream, "404 Not Found", "application/json", b"{}"),
    }
}

fn main() {
    let port = env::var("DETROIT_UI_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(4600u16);
    let _ = fs::create_dir_all(status_dir());
    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap_or_else(|e| {
        eprintln!("detroit web: cannot bind 127.0.0.1:{port} — {e}");
        std::process::exit(1);
    });
    println!("detroit web → http://127.0.0.1:{port}  (Ctrl+C to stop)");
    for stream in listener.incoming() {
        if let Ok(s) = stream { thread::spawn(move || handle(s)); }
    }
}

const PAGE: &str = r##"<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>detroit — factory floor</title>
<style>
:root{--bg:#000000;--panel:#101216;--field:#0a0c0f;--line:#4a515b;--ink:#ffffff;--mut:#9aa4af;--acc:#ff6308;--ok:#3fb950;--bad:#f85149;--run:#ff6308}
:root.light{--bg:#f3f4f6;--panel:#ffffff;--field:#ffffff;--line:#c2c8d0;--ink:#0a0c0f;--mut:#57606a;--acc:#ff6308;--ok:#1a7f37;--bad:#cf222e;--run:#ff6308}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 'Geist Mono',ui-monospace,SFMono-Regular,Menlo,monospace}
header{display:flex;align-items:center;gap:12px;padding:14px 20px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:5}
header h1{font-size:16px;margin:0;letter-spacing:.14em;text-transform:uppercase;font-weight:400}header .badge{background:var(--acc);color:#000000;font-weight:700;padding:2px 8px;border-radius:0;font-size:11px;letter-spacing:.1em}
header .pill{margin-left:auto;color:var(--mut);font-size:12px}
header .proj{color:var(--mut);font-size:12px;background:var(--field);border:1px solid var(--line);border-radius:0;padding:2px 8px}
main{display:grid;grid-template-columns:1.1fr 1fr 1.4fr;gap:14px;padding:16px;align-items:start}
@media(max-width:900px){main{grid-template-columns:1fr}}
.card{background:var(--panel);border:1px solid var(--line);border-radius:0;overflow:hidden}
.card>h2{margin:0;padding:10px 14px;font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--mut);border-bottom:1px solid var(--line);display:flex;justify-content:space-between}
.card .body{padding:12px 14px;display:flex;flex-direction:column;gap:10px}
.item{border:1px solid var(--line);border-radius:0;padding:9px 11px;background:var(--field)}
.item .n{font-weight:600}.item .m{color:var(--mut);font-size:12px}.tag{font-size:10px;color:var(--acc);border:1px solid var(--line);border-radius:0;padding:1px 6px;margin-left:6px}
.agent{display:flex;align-items:center;gap:9px}.dot{width:9px;height:9px;border-radius:50%;background:var(--run);flex:none;box-shadow:0 0 8px var(--run)}
.agent.done .dot{background:var(--ok);box-shadow:0 0 8px var(--ok)}.agent.fail .dot{background:var(--bad);box-shadow:0 0 8px var(--bad)}.agent.idle .dot{background:var(--mut);box-shadow:none}
pre.log{margin:0;padding:12px 14px;background:var(--field);max-height:60vh;overflow:auto;font-size:12px;color:var(--ink);white-space:pre-wrap;word-break:break-word}
.done-list{display:flex;flex-wrap:wrap;gap:6px}.done-list span{font-size:11px;color:var(--mut);border:1px solid var(--line);border-radius:0;padding:2px 7px}
a{color:var(--acc)}a.pr{display:block;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
button{font:inherit;background:var(--acc);color:#000000;border:0;border-radius:0;padding:7px 12px;font-weight:600;cursor:pointer;text-transform:uppercase;letter-spacing:.08em}
button.ghost{background:transparent;color:var(--ink);border:1px solid var(--line)}button.bad{background:var(--bad);color:#fff}button.ok{background:var(--ok);color:#fff}
input,textarea{width:100%;background:var(--field);border:1px solid var(--line);border-radius:0;color:var(--ink);padding:8px;font:inherit}
textarea{min-height:70px;resize:vertical}.row{display:flex;gap:8px}.row>*{flex:1}
.approve{border:1px solid var(--acc);border-radius:0;padding:10px;background:var(--panel)}.approve .m{max-height:120px;overflow:auto;white-space:pre-wrap;font-size:11px;color:var(--mut);margin:6px 0}
.empty{color:var(--mut);font-size:12px;font-style:italic}
.stages{display:flex;gap:0;padding:16px 16px 0;flex-wrap:wrap}
.stg{flex:1;min-width:110px;display:flex;align-items:center;gap:10px;background:var(--panel);border:1px solid var(--line);padding:12px 14px}
.stg+.stg{border-left:0}
.stg .si{font-size:22px;font-weight:600;color:var(--mut);font-family:'Geist Mono',ui-monospace,monospace;line-height:1;min-width:20px;text-align:center}
.stg .sn{font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--mut)}
.stg.on{background:var(--acc);border-color:var(--acc)}
.stg.on .si,.stg.on .sn{color:#000}
@media(max-width:760px){.stg{min-width:33%}.stg+.stg{border-left:1px solid var(--line)}}
.full{margin:14px 16px 0}
main.two{grid-template-columns:1fr 1.4fr}
@media(max-width:900px){main.two{grid-template-columns:1fr}}
.toolbar{display:flex;gap:8px;align-items:center;padding:12px 14px;border-bottom:1px solid var(--line);flex-wrap:wrap}
.toolbar input,.toolbar select{width:auto;flex:0 0 auto;background:var(--field);border:1px solid var(--line);color:var(--ink);padding:6px 8px;font:inherit}
.toolbar input#search{flex:1 1 220px}
.newtask{display:grid;gap:8px;padding:12px 14px;border-bottom:1px solid var(--line)}
.rows{display:flex;flex-direction:column}
.taskrow{display:flex;align-items:flex-start;gap:12px;padding:11px 14px;border-bottom:1px solid var(--line)}
.taskrow:last-child{border-bottom:0}
.tr-main{flex:1;min-width:0}.tr-name{font-weight:600}.tr-prev{color:var(--mut);font-size:12px;margin-top:3px}
.tr-repo{font-size:11px;color:var(--acc);white-space:nowrap;padding-top:2px}
.chip{font-size:10px;color:var(--mut);border:1px solid var(--line);padding:1px 6px;margin-left:6px;text-transform:uppercase;letter-spacing:.06em}
.badge-st{font-size:10px;text-transform:uppercase;letter-spacing:.1em;padding:3px 7px;border:1px solid var(--line);white-space:nowrap;flex:none;min-width:64px;text-align:center}
.badge-st.queued{color:var(--mut)}
.badge-st.running{color:#000;background:var(--acc);border-color:var(--acc)}
.badge-st.awaiting{color:#000;background:#f0b429;border-color:#f0b429}
.badge-st.done{color:var(--ok);border-color:var(--ok)}
.tbtn{margin-left:12px;background:transparent;color:var(--ink);border:1px solid var(--line);padding:4px 9px;cursor:pointer;font-size:13px;line-height:1}
.tbtn:hover{border-color:var(--acc);color:var(--acc)}
</style><script>(function(){try{if(localStorage.getItem('detroit-theme')==='light')document.documentElement.classList.add('light')}catch(e){}})()</script></head><body>
<header><span class="badge">DETROIT</span><h1>factory floor</h1><code class="proj" id="proj" title="projects folder — where the factory runs"></code><span class="pill" id="pill">connecting…</span><button class="tbtn" id="themebtn" onclick="toggleTheme()" title="Toggle light / dark">☀</button></header>
<div class="stages" id="stages"></div>
<section class="card full">
  <h2>Queue <span id="qc"></span></h2>
  <div class="toolbar">
    <input id="search" placeholder="Search issues…" oninput="render()">
    <select id="f-label" onchange="render()"><option value="">All labels</option></select>
    <select id="f-status" onchange="render()"><option value="">All status</option><option value="queued">Queued</option><option value="running">Running</option><option value="awaiting">Awaiting</option><option value="done">Done</option></select>
    <span style="flex:1"></span>
    <button class="ghost" onclick="toggleNew()">+ New</button>
    <button onclick="run(1)">▶ Run one</button>
    <button class="ghost" onclick="run(3)">▶ Run ×3</button>
  </div>
  <div id="newtask" class="newtask" style="display:none">
    <input id="t-name" placeholder="task name (e.g. add-dark-mode)">
    <input id="t-repo" placeholder="repo (optional — blank = new repo)">
    <input id="t-labels" placeholder="labels (optional, comma-separated)">
    <textarea id="t-body" placeholder="What should the agent build?"></textarea>
    <div class="row"><button onclick="addTask()">Add task</button><span style="flex:3"></span></div>
  </div>
  <div id="awaiting"></div>
  <div id="rows" class="rows"><span class="empty">no tasks</span></div>
</section>
<main class="two">
  <section class="card">
    <h2>Agents</h2>
    <div class="body" id="agents"><span class="empty">idle</span></div>
    <h2 style="border-top:1px solid var(--line)">Pull requests</h2>
    <div class="body" id="prs"><span class="empty">none</span></div>
  </section>
  <section class="card">
    <h2>Log <span id="lf" class="m"></span></h2>
    <pre class="log" id="log">—</pre>
  </section>
</main>
<script>
const $=s=>document.querySelector(s), esc=t=>(t||"").replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])), q=encodeURIComponent;
let S={tasks:[],done:[],labels:[],stats:{},agents:[],awaiting:[],prs:[]}, stuck=false;
const STAGES=['triage','plan','build','test','ship','verify'];
function stageIdx(s){s=(s||'').toLowerCase();
  if(/verif|screenshot/.test(s))return 5;
  if(/ship|pull request|\bpr\b|\bci\b|open/.test(s))return 4;
  if(/gate|test|fix|check/.test(s))return 3;
  if(/prepar|scaffold|cod|build|implement|branch|worktree/.test(s))return 2;
  if(/plan/.test(s))return 1;
  if(/pick|rout|triage/.test(s))return 0;
  return -1;}
function cls(s){s=(s||'').toLowerCase();return s.includes('✓')||s.includes('done')?'done':s.includes('✗')||s.includes('fail')?'fail':s.includes('idle')?'idle':''}
function toggleNew(){const n=$('#newtask');n.style.display=n.style.display==='none'?'grid':'none'}
async function addTask(){const name=$('#t-name').value,repo=$('#t-repo').value,labels=$('#t-labels').value,body=$('#t-body').value;
  if(!body.trim())return; await fetch(`/api/task?name=${q(name)}&repo=${q(repo)}&labels=${q(labels)}`,{method:'POST',body});
  $('#t-name').value=$('#t-repo').value=$('#t-labels').value=$('#t-body').value='';toggleNew();tick()}
async function run(p){await fetch(`/api/run?parallel=${p}`,{method:'POST'});tick()}
async function decide(id,d){await fetch(`/api/approve?id=${q(id)}&decision=${d}`,{method:'POST'});tick()}
function render(){
  const term=($('#search').value||'').toLowerCase(), fl=$('#f-label').value, fst=$('#f-status').value;
  const list=[...(S.tasks||[]), ...(S.done||[]).map(d=>({name:d,repo:'',preview:'',labels:[],status:'done'}))]
    .filter(t=>!term||`${t.name} ${t.repo} ${t.preview} ${(t.labels||[]).join(' ')}`.toLowerCase().includes(term))
    .filter(t=>!fl||(t.labels||[]).includes(fl))
    .filter(t=>!fst||t.status===fst);
  $('#qc').textContent=list.length||'';
  $('#rows').innerHTML=list.length?list.map(t=>`<div class="taskrow"><span class="badge-st ${t.status}">${t.status}</span><div class="tr-main"><span class="tr-name">${esc(t.name)}</span>${(t.labels||[]).map(l=>`<span class="chip">${esc(l)}</span>`).join('')}<div class="tr-prev">${esc(t.preview)}</div></div><span class="tr-repo">${t.repo?esc(t.repo):(t.status==='done'?'':'new repo')}</span></div>`).join(''):'<span class="empty">no matching tasks</span>';
}
async function tick(){
  try{S=await(await fetch('/api/state')).json();stuck=false;
    $('#pill').textContent='live · '+new Date().toLocaleTimeString(); $('#proj').textContent=S.projects?('▸ '+S.projects):'';
    const counts=[0,0,0,0,0,0]; (S.agents||[]).forEach(a=>{const i=stageIdx(a.status); if(i>=0)counts[i]++});
    $('#stages').innerHTML=STAGES.map((n,i)=>`<div class="stg${counts[i]?' on':''}"><span class="si">${counts[i]||'·'}</span><span class="sn">${n}</span></div>`).join('');
    const sel=$('#f-label'), cur=sel.value;
    sel.innerHTML='<option value="">All labels</option>'+(S.labels||[]).map(l=>`<option${l===cur?' selected':''}>${esc(l)}</option>`).join('');
    $('#awaiting').innerHTML=(S.awaiting||[]).map(a=>`<div class="approve"><b>PLAN READY · AGENT ${esc(a.id)}</b><div class="m">${esc(a.plan)}</div><div class="row"><button class="ok" onclick="decide('${esc(a.id)}','approve')">Approve</button><button class="bad" onclick="decide('${esc(a.id)}','reject')">Reject</button></div></div>`).join('');
    $('#agents').innerHTML=(S.agents||[]).length?S.agents.map(a=>`<div class="agent ${cls(a.status)}"><span class="dot"></span><div><div class="n">agent ${esc(a.id)}</div><div class="m">${esc(a.status)||'—'}</div></div></div>`).join(''):'<span class="empty">idle</span>';
    $('#prs').innerHTML=(S.prs||[]).length?S.prs.map(u=>`<a class="pr" href="${esc(u)}" target="_blank">${esc(u.replace('https://github.com/',''))}</a>`).join(''):'<span class="empty">none</span>';
    $('#lf').textContent=S.logfile; $('#log').textContent=S.log||'—'; const l=$('#log'); l.scrollTop=l.scrollHeight;
    render();
  }catch(e){if(!stuck){$('#pill').textContent='disconnected';stuck=true}}
}
function themeIcon(){$('#themebtn').textContent=document.documentElement.classList.contains('light')?'☾':'☀'}
function toggleTheme(){const l=document.documentElement.classList.toggle('light');try{localStorage.setItem('detroit-theme',l?'light':'dark')}catch(e){}themeIcon()}
themeIcon();tick();setInterval(tick,2000);
</script></body></html>"##;
