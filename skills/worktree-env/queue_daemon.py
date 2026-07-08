#!/usr/bin/env python3
"""queue_daemon.py -- local HTTP arbitration daemon for worktree-env's shared
lane mode.

Single process, stdlib only (no external dependencies to install). Tracks,
per repo (keyed by principal repo basename), which worktree currently holds
the shared lane and a FIFO queue of worktrees waiting for it. NEVER touches
Docker -- worktree-env.sh does all the actual `docker compose` work once a
claim is granted.

Started/stopped via `worktree-env.sh queue up|down` (compose.queue.yaml),
one instance per machine, independent of any project or worktree.

API (all local to 127.0.0.1):
  POST /claim     {repo, worktree, mode, idle_timeout} -- blocks (long-poll)
                  until granted, returns {"granted": true}
  POST /heartbeat {repo, worktree}                     -- refresh the holder's
                  activity timestamp (interactive mode only)
  POST /release   {repo, worktree}                     -- explicit release;
                  also cancels a pending queue entry for the same worktree
  GET  /status?repo=...                                -- current holder + queue
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# Bind host: 127.0.0.1 for direct/local runs (not reachable from the network).
# The containerized daemon (compose.queue.yaml) overrides this to 0.0.0.0,
# because a socket bound to 127.0.0.1 *inside* the container is unreachable
# through Docker's port-forwarding NAT; the host-side publish there is what
# actually restricts external reachability to 127.0.0.1.
HOST = os.environ.get("WT_QUEUE_BIND_HOST", "127.0.0.1")
PORT = int(os.environ.get("WT_QUEUE_PORT", "8765"))
STATE_FILE = os.environ.get("WT_QUEUE_STATE_FILE") or os.path.expanduser(
    "~/.worktree-env/queue_state.json"
)
# How often the watchdog sweeps for idle interactive holders past their timeout.
WATCHDOG_INTERVAL = float(os.environ.get("WT_QUEUE_WATCHDOG_INTERVAL", "15"))
# How often a blocked /claim re-checks whether it has become the holder.
CLAIM_POLL_INTERVAL = 0.5
DEFAULT_IDLE_TIMEOUT = 2700  # 45 minutes, mirrors WT_SHARED_IDLE_TIMEOUT's default

lock = threading.Lock()
cond = threading.Condition(lock)
state = {}  # repo -> {"holder": {...} | None, "queue": [ {...}, ... ]}


def _load_state():
    global state
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        state = {}


def _persist_state():
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE_FILE)


def _repo_state(repo):
    return state.setdefault(repo, {"holder": None, "queue": []})


def _grant_next(repo_state):
    """Pop the next queued worktree (if any) and make it the holder.

    Caller must hold `lock`.
    """
    if repo_state["queue"]:
        nxt = repo_state["queue"].pop(0)
        nxt["last_heartbeat"] = time.time()
        repo_state["holder"] = nxt
    else:
        repo_state["holder"] = None


def handle_claim(repo, worktree, mode, idle_timeout):
    with cond:
        rs = _repo_state(repo)
        holder = rs["holder"]

        if holder is None:
            rs["holder"] = {
                "worktree": worktree,
                "mode": mode,
                "idle_timeout": idle_timeout,
                "last_heartbeat": time.time(),
            }
            _persist_state()
            return {"granted": True}

        if holder["worktree"] == worktree:
            # Reconnect (e.g. after a lost HTTP connection) -- idempotent grant.
            holder["last_heartbeat"] = time.time()
            holder["mode"] = mode
            holder["idle_timeout"] = idle_timeout
            _persist_state()
            return {"granted": True}

        if not any(q["worktree"] == worktree for q in rs["queue"]):
            rs["queue"].append(
                {"worktree": worktree, "mode": mode, "idle_timeout": idle_timeout}
            )
            _persist_state()

        # Block until this worktree becomes the holder. cond.wait() releases
        # the lock while waiting so other requests (heartbeat/release/status,
        # each on their own thread) keep being served.
        while True:
            rs = _repo_state(repo)
            holder = rs["holder"]
            if holder is not None and holder["worktree"] == worktree:
                return {"granted": True}
            cond.wait(timeout=CLAIM_POLL_INTERVAL)


def handle_heartbeat(repo, worktree):
    with lock:
        rs = _repo_state(repo)
        holder = rs["holder"]
        if holder is not None and holder["worktree"] == worktree:
            holder["last_heartbeat"] = time.time()
            _persist_state()
            return {"ok": True}
        return {"ok": False, "error": "not holder"}


def handle_release(repo, worktree):
    with cond:
        rs = _repo_state(repo)
        holder = rs["holder"]
        released = False
        if holder is not None and holder["worktree"] == worktree:
            _grant_next(rs)
            released = True
        else:
            before = len(rs["queue"])
            rs["queue"] = [q for q in rs["queue"] if q["worktree"] != worktree]
            released = len(rs["queue"]) != before
        _persist_state()
        cond.notify_all()
        return {"released": released}


def handle_status(repo):
    with lock:
        rs = state.get(repo, {"holder": None, "queue": []})
        return {"holder": rs["holder"], "queue": rs["queue"]}


def watchdog():
    """Auto-release interactive holders that stopped heartbeating past their
    idle_timeout, promoting the next queued worktree without any manual
    action. Test-mode holders are never auto-released here: they are torn
    down synchronously by the CLI that claimed them.
    """
    while True:
        time.sleep(WATCHDOG_INTERVAL)
        with cond:
            now = time.time()
            changed = False
            for rs in state.values():
                holder = rs["holder"]
                if holder and holder.get("mode") == "interactive":
                    timeout = holder.get("idle_timeout", DEFAULT_IDLE_TIMEOUT)
                    if now - holder.get("last_heartbeat", now) > timeout:
                        _grant_next(rs)
                        changed = True
            if changed:
                _persist_state()
                cond.notify_all()


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw or b"{}")

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            body = self._read_json()
            if path == "/claim":
                result = handle_claim(
                    body["repo"],
                    body["worktree"],
                    body.get("mode", "interactive"),
                    int(body.get("idle_timeout", DEFAULT_IDLE_TIMEOUT)),
                )
            elif path == "/heartbeat":
                result = handle_heartbeat(body["repo"], body["worktree"])
            elif path == "/release":
                result = handle_release(body["repo"], body["worktree"])
            else:
                self._send_json(404, {"error": "not found"})
                return
            self._send_json(200, result)
        except (KeyError, ValueError) as e:
            self._send_json(400, {"error": str(e)})

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/status":
            qs = parse_qs(parsed.query)
            repo = qs.get("repo", [None])[0]
            if not repo:
                self._send_json(400, {"error": "missing repo"})
                return
            self._send_json(200, handle_status(repo))
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        pass  # keep stdout quiet -- this runs as a background dev daemon


def main():
    _load_state()
    threading.Thread(target=watchdog, daemon=True).start()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"queue_daemon listening on {HOST}:{PORT}, state={STATE_FILE}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
