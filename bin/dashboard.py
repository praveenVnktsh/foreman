#!/usr/bin/env python3
"""One page saying what this foreman is doing, and a box for talking to it.

    dashboard.py                 serve on 127.0.0.1:$FOREMAN_DASHBOARD_PORT
    dashboard.py --once          print the picture as JSON and exit

THREE BANDS, in the order an operator actually asks:

    STUCK    is anything wrong, and what do I type to fix it
    NOW      what is running, by board and card
    MACHINE  is the host fit -- tick, disk, memory, rate limits, credentials

There is deliberately no exhaustive per-card table. A board with forty
finished cards has forty rows of history nobody reads, and the rows that
matter -- a card holding a slot, a card with a live agent -- are the ones
`--overview` already selects.

IT DERIVES NOTHING. Every number comes from `reconcile.py --overview`, which
is the file that already re-derives this machine's position for the tick. The
dashboard this replaces parsed `boards.toml` with its own `tomllib`, globbed
`instances/<board>/cards/` by hand and carried its own copy of card-state
logic -- a third reader of a layout two other files own. It kept answering
confidently while the single-foreman change moved that layout underneath it,
and it still carried a skip for a `cards/orphans` directory nothing has
written for months. A view that derives is a view that is quietly wrong.

IT IS HARNESS-AGNOSTIC, because the person watching a board is not always the
person who chose the CLI under it. Agents reach this page through
`$HARNESS_SH`, the registry that merges every harness, so a foreman running on
OpenCode and one running on Claude Code render identically.

IT CHANGES NOTHING ABOUT A CARD. The only write it makes is a message into the
tick's inbox. Restarting a tick, halting a board and sweeping a card all have
commands that already exist and already take a lock; a second actor doing them
from a browser is how two ticks end up dispatching. Every problem in the STUCK
band names the command instead.

LOOPBACK ONLY. The bind is 127.0.0.1 and the publisher in front is what joins
it to a tailnet (`tailscale serve`), so reaching this page requires being on
the tailnet and this process never has to judge who is asking.
"""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INSTALL_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECONCILE = os.path.join(INSTALL_ROOT, "skills", "board", "reconcile.py")
BOARDS_PY = os.path.join(INSTALL_ROOT, "bin", "boards.py")

HOME = os.environ.get("FOREMAN_HOME") or os.path.join(os.path.expanduser("~"), ".foreman")
PORT = int(os.environ.get("FOREMAN_DASHBOARD_PORT", "8429"))

# How long the page waits before asking again. The overview is local files
# only, so this costs a directory walk and one `$HARNESS_SH list`; it is not
# on any `gh` path. Slow enough that a tab left open all day is not a load.
REFRESH_SECONDS = int(os.environ.get("FOREMAN_DASHBOARD_REFRESH", "20"))

# How long `--overview` may take before the page is told the machine is not
# answering. Generous, because it walks every board's cards/ on a host that
# may be mid-build; short enough that a wedged call does not hold a worker.
OVERVIEW_TIMEOUT = 60

# The longest message the inbox accepts, in bytes. A message is a sentence to
# a tick, not a document: the tick reads the whole inbox at the top of every
# pass, and something long enough to crowd out its own instructions is a
# message that changes what the tick is rather than what it does.
MAX_MESSAGE_BYTES = 4096


def die(message: str) -> None:
    sys.stderr.write(f"dashboard: {message}\n")
    raise SystemExit(1)


def first_board() -> str:
    """Any declared board, because `--overview` answers for the MACHINE.

    reconcile.py sources config.sh, which refuses to guess a board -- so this
    has to name one even though the question is machine-wide. supervise.sh
    takes the same shortcut for the same reason, with the same comment: every
    declared board yields the same machine-wide values, so the first one
    answers.
    """
    try:
        done = subprocess.run([BOARDS_PY, "--list"], capture_output=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"could not run {BOARDS_PY}: {exc}") from exc
    if done.returncode != 0:
        raise RuntimeError(done.stderr.decode().strip() or "boards.py --list failed")
    names = [n for n in done.stdout.decode().split("\0") if n]
    if not names:
        raise RuntimeError(f"no boards declared in {HOME}/boards.toml")
    return names[0]


def overview() -> dict:
    """`reconcile.py --overview`, parsed.

    A FAILURE IS A PICTURE TOO. Every error here becomes a rendered page
    saying what could not be read, never a stack trace and never a blank
    screen: this page is the thing an operator opens when something is already
    wrong, so it is the last thing that may fail silently.
    """
    env = dict(os.environ)
    env["FOREMAN_HOME"] = HOME
    try:
        env["FOREMAN_INSTANCE"] = first_board()
    except RuntimeError as exc:
        return _broken(str(exc))
    try:
        done = subprocess.run([RECONCILE, "--overview"], capture_output=True,
                              env=env, timeout=OVERVIEW_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return _broken(f"reconcile.py --overview did not answer: {exc}")
    if done.returncode != 0:
        return _broken(done.stderr.decode().strip()
                       or f"reconcile.py --overview exited {done.returncode}")
    try:
        return json.loads(done.stdout.decode())
    except json.JSONDecodeError as exc:
        return _broken(f"reconcile.py --overview did not print JSON: {exc}")


def _broken(detail: str) -> dict:
    """The picture for a machine this process cannot read.

    Shaped exactly like a real one, so the page renders it through the same
    path rather than branching. The band an operator reads first is the one
    that carries the bad news.
    """
    return {
        "at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tick": {"running": False, "name": "?"},
        "machine": {"foreman_home": HOME, "rate_limits": []},
        "boards": [], "agents": [], "agents_finished": 0, "registry_ok": False,
        "inbox": {"waiting": [], "done_count": 0},
        "problems": [{"severity": "critical", "kind": "dashboard-blind",
                      "detail": detail,
                      "fix": "check FOREMAN_HOME and that the install is intact"}],
    }


# A message filename: sortable, unique, and safe. The timestamp is what orders
# the tick's reading, and the suffix is what keeps two messages sent in the
# same second from being one.
def message_filename() -> str:
    return (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            + "-" + secrets.token_hex(3) + ".md")


def write_message(text: str) -> dict:
    """Append one message to the tick's inbox.

    ONE FILE PER MESSAGE, never an appended log: the tick moves each message
    aside when it has acted on it, and a single file cannot be half-answered.

    Written to a temp name in the same directory and renamed into place, so a
    tick reading the inbox mid-write never sees half a message. The same rule
    bin/resolve-ids.py follows for ids.env.
    """
    text = text.strip()
    if not text:
        raise ValueError("an empty message is not a message")
    encoded = text.encode()
    if len(encoded) > MAX_MESSAGE_BYTES:
        raise ValueError(f"message is {len(encoded)} bytes; the limit is "
                         f"{MAX_MESSAGE_BYTES}")
    directory = os.path.join(HOME, "inbox")
    os.makedirs(directory, exist_ok=True)
    name = message_filename()
    final = os.path.join(directory, name)
    temp = os.path.join(directory, "." + name + ".partial")
    body = (f"# sent {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}"
            f" from the dashboard\n\n{text}\n")
    with open(temp, "w") as fh:
        fh.write(body)
    os.replace(temp, final)
    return {"queued": name}


# =============================================================================
# The page. One file, no assets, no CDN: it is served to a tailnet and has to
# render on a phone with no network beyond this host.
# =============================================================================

PAGE = r"""<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>foreman</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f6f6f4; --fg: #14161a; --dim: #5d6470; --line: #d9dbe0;
    --card: #ffffff; --crit: #b3261e; --warn: #8a5a00; --info: #2b5c8a;
    --ok: #1f6f43;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14161a; --fg: #e8eaee; --dim: #949bab; --line: #2b2f37;
      --card: #1b1e24; --crit: #ef6b62; --warn: #d6a13a; --info: #74aede;
      --ok: #5fc48b;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 0 16px 48px;
    padding-top: env(safe-area-inset-top, 0px);
    background: var(--bg); color: var(--fg);
    font: 14px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  }
  header {
    display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: baseline;
    padding: 16px 0 12px; border-bottom: 1px solid var(--line); margin-bottom: 18px;
  }
  h1 { font-size: 15px; margin: 0; letter-spacing: .08em; text-transform: uppercase; }
  h2 {
    font-size: 11px; letter-spacing: .14em; text-transform: uppercase;
    color: var(--dim); margin: 26px 0 8px; font-weight: 600;
  }
  .dim { color: var(--dim); }
  .row {
    background: var(--card); border: 1px solid var(--line); border-radius: 6px;
    padding: 10px 12px; margin-bottom: 6px;
  }
  .row.crit { border-left: 3px solid var(--crit); }
  .row.warn { border-left: 3px solid var(--warn); }
  .row.info { border-left: 3px solid var(--info); }
  .tag {
    font-size: 11px; letter-spacing: .06em; text-transform: uppercase;
    margin-right: 8px;
  }
  .crit .tag { color: var(--crit); }
  .warn .tag { color: var(--warn); }
  .info .tag { color: var(--info); }
  .fix {
    display: block; margin-top: 6px; color: var(--dim);
    word-break: break-all; white-space: pre-wrap;
  }
  .allgood { color: var(--ok); }
  table { width: 100%; border-collapse: collapse; }
  th, td {
    text-align: left; padding: 6px 10px 6px 0; border-bottom: 1px solid var(--line);
    vertical-align: top;
  }
  th { color: var(--dim); font-weight: 600; font-size: 11px;
       letter-spacing: .08em; text-transform: uppercase; }
  .wrap { overflow-x: auto; }
  .pill {
    display: inline-block; padding: 1px 7px; border-radius: 10px;
    border: 1px solid var(--line); font-size: 12px;
  }
  .grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 6px;
  }
  .stat { background: var(--card); border: 1px solid var(--line);
          border-radius: 6px; padding: 10px 12px; }
  .stat b { display: block; font-size: 17px; font-weight: 600; margin-top: 2px; }
  form { display: flex; flex-direction: column; gap: 8px; max-width: 640px; }
  textarea {
    width: 100%; min-height: 76px; resize: vertical; padding: 10px;
    background: var(--card); color: var(--fg);
    border: 1px solid var(--line); border-radius: 6px; font: inherit;
  }
  button {
    align-self: flex-start; padding: 8px 18px; font: inherit; cursor: pointer;
    background: var(--fg); color: var(--bg); border: 0; border-radius: 6px;
  }
  button:disabled { opacity: .5; cursor: default; }
  #sent { color: var(--ok); }
  @media (max-width: 520px) { body { padding: 0 12px 40px; } }
</style>

<header>
  <h1>foreman</h1>
  <span class="dim" id="tick">…</span>
  <span class="dim" id="at"></span>
</header>

<h2>Stuck</h2>
<div id="problems"></div>

<h2>Now</h2>
<div id="now"></div>

<h2>Machine</h2>
<div class="grid" id="machine"></div>

<h2>Say something to the tick</h2>
<form id="msg">
  <textarea id="text" placeholder="Read at the top of the tick's next pass."></textarea>
  <button type="submit">Send</button>
  <span id="sent"></span>
</form>

<script>
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g,
  (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));

function ago(s) {
  if (s == null) return "?";
  s = Math.floor(s);
  if (s < 60) return s + "s";
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h" + String(Math.floor((s % 3600) / 60)).padStart(2, "0") + "m";
  return Math.floor(s / 86400) + "d" + String(Math.floor((s % 86400) / 3600)).padStart(2, "0") + "h";
}

function render(d) {
  const t = d.tick || {};
  $("tick").textContent = t.running
    ? `tick up ${ago(t.age_seconds)} · ${t.phase || t.state || ""}`
    : "NO TICK RUNNING";
  $("tick").className = t.running ? "dim" : "";
  $("tick").style.color = t.running ? "" : "var(--crit)";
  $("at").textContent = d.at || "";

  const probs = d.problems || [];
  $("problems").innerHTML = probs.length
    ? probs.map((p) => `<div class="row ${esc(p.severity)}">
        <span class="tag">${esc(p.severity)}</span>${esc(p.detail)}
        ${p.fix ? `<code class="fix">${esc(p.fix)}</code>` : ""}</div>`).join("")
    : `<div class="row"><span class="allgood">Nothing is stuck.</span></div>`;

  const boards = d.boards || [];
  const inbox = d.inbox || {};
  let now = "";
  if (inbox.waiting && inbox.waiting.length) {
    now += `<div class="row info"><span class="tag">inbox</span>${inbox.waiting.length}
      message(s) waiting for the next pass</div>`;
  }
  if (!boards.length) now += `<div class="row dim">No boards declared.</div>`;
  for (const b of boards) {
    const rows = [];
    for (const c of (b.cards || [])) {
      const who = (c.agents || []).map((a) => `${esc(a.role)} <span class="dim">${esc(a.phase)}</span>`).join(", ");
      rows.push(`<tr><td>${esc(c.ticket)}</td><td>${who || '<span class="dim">no agent</span>'}</td>
        <td>${esc(c.last_action || "—")}</td><td>${ago(c.idle_seconds)}</td></tr>`);
    }
    now += `<div class="row">
      <b>${esc(b.name)}</b>
      <span class="pill">${b.slots_held || 0} in flight</span>
      ${b.halted ? '<span class="pill" style="color:var(--warn)">halted</span>' : ""}
      <span class="dim"> · served ${ago(b.last_served_seconds)} ago · ${b.cards_total || 0} cards on disk</span>
      ${rows.length ? `<div class="wrap"><table>
        <tr><th>card</th><th>agent</th><th>last</th><th>idle</th></tr>
        ${rows.join("")}</table></div>`
        : `<div class="dim" style="margin-top:6px">nothing in flight</div>`}
    </div>`;
  }
  $("now").innerHTML = now;

  const m = d.machine || {};
  const mb = (v) => v == null ? "—" : (v > 1024 ? (v / 1024).toFixed(1) + " GB" : Math.round(v) + " MB");
  const limited = (m.rate_limits || []).filter((r) => !r.expired);
  $("machine").innerHTML = `
    <div class="stat"><span class="dim">disk free</span><b>${mb(m.disk_free_mb)}</b></div>
    <div class="stat"><span class="dim">memory free</span><b>${mb(m.memory_free_mb)}</b></div>
    <div class="stat"><span class="dim">host ceiling</span><b>${esc(m.host_max_concurrent)}</b></div>
    <div class="stat"><span class="dim">credentials</span><b style="color:${m.linear_key && m.mcp_config ? "var(--ok)" : "var(--crit)"}">
      ${m.linear_key ? "key" : "no key"} · ${m.mcp_config ? "mcp" : "no mcp"}</b></div>
    <div class="stat"><span class="dim">rate limited</span><b style="color:${limited.length ? "var(--warn)" : "var(--ok)"}">
      ${limited.length ? limited.map((r) => esc(r.model)).join(", ") : "none"}</b></div>
    <div class="stat"><span class="dim">agents live / finished</span><b>${(d.agents || []).length} / ${d.agents_finished || 0}</b></div>`;
}

async function tick() {
  try {
    // RELATIVE, never "/api": this page is mounted behind `tailscale serve`
    // under a path prefix, so an absolute URL asks the proxy's root and gets
    // whatever else is published there.
    const r = await fetch("api", {cache: "no-store"});
    render(await r.json());
  } catch (e) {
    $("problems").innerHTML =
      `<div class="row crit"><span class="tag">critical</span>the dashboard cannot reach its own server: ${esc(e)}</div>`;
  }
}

$("msg").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const text = $("text").value.trim();
  if (!text) return;
  const button = ev.target.querySelector("button");
  button.disabled = true;
  try {
    const r = await fetch("message", {method: "POST", body: text});
    const out = await r.json();
    if (out.error) { $("sent").textContent = out.error; $("sent").style.color = "var(--crit)"; }
    else { $("text").value = ""; $("sent").textContent = "queued " + out.queued; $("sent").style.color = ""; tick(); }
  } catch (e) {
    $("sent").textContent = String(e);
  } finally {
    button.disabled = false;
  }
});

tick();
setInterval(tick, __REFRESH_MS__);
</script>
"""


class Handler(BaseHTTPRequestHandler):
    # MOUNTED ANYWHERE, under any name. `tailscale serve` publishes this
    # behind a path prefix -- `/foreman` on the machine it was built for, but
    # the prefix is the operator's to choose and this process is never told
    # it. So the ENDPOINTS are matched by their last segment, which the page
    # reaches with relative URLs, and everything else serves the page.
    #
    # Recognising endpoints rather than recognising the root is what makes the
    # prefix invisible: `/`, `/foreman/` and `/boards/foreman/` all render,
    # while only `.../api` and `.../message` do anything else. The dashboard
    # this replaces stripped a hardcoded "foreman" segment instead, which
    # served nothing the day it was published under a different name.
    ENDPOINTS = ("api", "message")

    def _route(self) -> str:
        path = self.path.split("?")[0]
        segments = [s for s in path.split("/") if s]
        last = segments[-1] if segments else ""
        return last if last in self.ENDPOINTS else ""

    def do_GET(self) -> None:
        if self._route() == "api":
            self._send(200, "application/json", json.dumps(overview()).encode())
            return
        body = PAGE.replace("__REFRESH_MS__", str(REFRESH_SECONDS * 1000))
        self._send(200, "text/html; charset=utf-8", body.encode())

    def do_POST(self) -> None:
        if self._route() != "message":
            self._send(404, "text/plain; charset=utf-8", b"not found\n")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        # Read at most one message's worth plus a byte, so an oversized body is
        # refused by the same rule write_message applies rather than buffered
        # whole first.
        raw = self.rfile.read(min(length, MAX_MESSAGE_BYTES + 1)) if length else b""
        try:
            result = write_message(raw.decode("utf-8", "replace"))
            code = 200
        except (ValueError, OSError) as exc:
            result, code = {"error": str(exc)}, 400
        self._send(code, "application/json", json.dumps(result).encode())

    def _send(self, code: int, ctype: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # Nothing here is cacheable: the whole page is a statement about right
        # now, and a proxy in front that cached it would show a stopped tick as
        # running.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        # Silent by default. This runs under a systemd unit whose journal is
        # read when something is wrong, and one line per poll every twenty
        # seconds is how that journal becomes unreadable.
        pass


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--once":
        json.dump(overview(), sys.stdout, indent=2)
        print()
        return 0
    if argv:
        die(f"unknown argument: {argv[0]} (expected --once, or nothing to serve)")
    # LOOPBACK. See the module docstring: the publisher in front is what
    # decides who may reach this, and binding anything else would put an
    # unauthenticated page on every interface the host has.
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write(f"dashboard: serving http://127.0.0.1:{PORT} from {HOME}\n")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
