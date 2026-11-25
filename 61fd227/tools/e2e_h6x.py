#!/usr/bin/python3 -I
"""H6 at its edges (61fd227 validation): ack_updates moves seenAt with A acknowledged and B not. Derived from the kit's e2e_stdio.py, setup unchanged.
End-to-end checks of the real at_mcp-stdio binary, run inside box.sh.

Everything it talks to is local and synthetic: a fake PDS and Constellation
(HTTP), a fake Spacedust (WebSocket), a raw JSON-RPC MCP client, and an external
SQLite queue that reads with get_updates, commits, then acknowledges.

Usage (inside the sandbox): python3 -I /work/e2e_stdio.py
"""
import base64, datetime as dt, hashlib, http.server, json, os, queue as Q, re, signal, socket, socketserver
import sqlite3, struct, subprocess, sys, threading, time, urllib.parse

ME = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
MINE = f"at://{ME}/app.bsky.feed.post/3kmine22222a2"
ALPHA = "234567abcdefghijklmnopqrstuvwxyz"
WORK = os.environ.get("E2E_WORK", "/work/e2e")


def report(name, value):
    print(f"RESULT\t{name}\t{value!r}", flush=True)


def tid(n, sec=None):
    v = ((int(sec or time.time()) * 1_000_000 + n) << 10) | 1
    return "".join(ALPHA[(v >> (i * 5)) & 31] for i in range(12, -1, -1))


def sender(n):
    s, x = "", n
    for _ in range(24):
        s = ALPHA[x % 32] + s
        x //= 32
    return "did:plc:" + s


class World:
    posts, down, gone, bots = {}, False, set(), set()
    notifs, seen = [], []
    sockets, lock = [], threading.Lock()


class Http(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def out(self, body, status=200):
        b = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path.endswith("/com.atproto.server.createSession"):
            return self.out({"did": ME, "handle": body.get("identifier"), "accessJwt": "fixture", "refreshJwt": "fixture"})
        if self.path.endswith("/app.bsky.notification.updateSeen"):
            World.seen.append(body.get("seenAt"))
            return self.out({})
        self.out({"error": "UnsupportedFixtureCall"}, 404)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        p = u.path
        if p == "/links/all":
            return self.out({"links": {}})
        if p.startswith("/links") or "backlinks" in p:
            return self.out({"total": 0, "records": [], "cursor": None})
        if p.endswith("/app.bsky.actor.getPreferences"):
            return self.out({"preferences": []})
        if p.endswith("/app.bsky.notification.listNotifications"):
            wanted = q.get("reasons", [])
            return self.out({"notifications": [n for n in World.notifs if not wanted or n["reason"] in wanted]})
        if p.endswith("/app.bsky.actor.getProfiles"):
            return self.out({"profiles": [{"did": d, "handle": f"u{d[-6:]}.test", "viewer": {}} for d in q.get("actors", [])]})
        if p.endswith("/app.bsky.feed.getPosts"):
            if World.down:
                return self.out({"error": "InternalServerError"}, 500)
            rows = []
            for uri in q.get("uris", []):
                if uri in World.gone or uri not in World.posts:
                    continue
                did = uri.split("/")[2]
                now = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
                rows.append({"uri": uri, "cid": "bafyfixture", "indexedAt": now, "author": {"did": did, "handle": f"u{did[-6:]}.test",
                                        "labels": [{"src": did, "uri": uri, "val": "bot", "cts": now}] if did in World.bots else []},
                             "record": {"$type": "app.bsky.feed.post", "text": World.posts[uri], "createdAt": now,
                                        "reply": {"root": {"uri": MINE, "cid": "x"}, "parent": {"uri": MINE, "cid": "x"}}}})
            return self.out({"posts": rows})
        self.out({"error": "UnsupportedFixtureCall", "message": p}, 404)


class Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def ws_serve(sock):
    while True:
        c, _ = sock.accept()
        threading.Thread(target=ws_client, args=(c,), daemon=True).start()


def ws_client(c):
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            data += c.recv(4096)
        key = [l.split(b":", 1)[1].strip() for l in data.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key")][0]
        acc = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + acc + b"\r\n\r\n")
        with World.lock:
            World.sockets.append(c)
        while c.recv(4096):
            pass
    except OSError:
        pass
    with World.lock:
        if c in World.sockets:
            World.sockets.remove(c)


def emit(obj):
    b = json.dumps(obj).encode()
    head = bytes([0x81]) + (bytes([len(b)]) if len(b) < 126 else bytes([126]) + struct.pack(">H", len(b)))
    with World.lock:
        for c in list(World.sockets):
            try:
                c.sendall(head + b)
            except OSError:
                pass


def reply_link(n, text="a synthetic reply", who=None):
    who = who or sender(n)
    uri = f"at://{who}/app.bsky.feed.post/{tid(n)}"
    World.posts[uri] = text
    emit({"kind": "link", "origin": "live", "link": {"operation": "create", "source": "app.bsky.feed.post:reply.parent.uri",
                                                     "source_record": uri, "source_rev": uri.rsplit("/", 1)[1], "subject": MINE}})
    return uri


class Server:
    def __init__(self, ports, state):
        env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "HOME": "/tmp", "RELEASE_TMP": "/tmp",
               "RELEASE_COOKIE": "isolated-test-cookie", "AT_MCP_ENV_FILE": "/tmp/no-env-file", "AT_MCP_HANDLE": "alice.test",
               "AT_MCP_APP_PASSWORD": "fixture-password", "AT_MCP_SERVICE": f"http://127.0.0.1:{ports[0]}",
               "AT_MCP_STATE_DIR": state, "AT_MCP_STATE_WAIT_SECONDS": "20", "AT_MCP_TOOLS": "full", "AT_MCP_LISTENERS": "1",
               "AT_MCP_SPACEDUST_URL": f"ws://127.0.0.1:{ports[1]}", "AT_MCP_CONSTELLATION_URL": f"http://127.0.0.1:{ports[0]}"}
        self.err = open(state + ".stderr", "ab")
        self.p = subprocess.Popen(["/rel/bin/at_mcp-stdio"], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=self.err, start_new_session=True)
        self.inbox, self.notes, self.id = Q.Queue(), [], 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if "id" in m and ("result" in m or "error" in m):
                self.inbox.put(m)
            elif m.get("method"):
                self.notes.append(m)
        self.inbox.put(None)

    def send(self, obj):
        self.p.stdin.write((json.dumps(obj) + "\n").encode())
        self.p.stdin.flush()

    def req(self, method, params=None, timeout=25):
        self.id += 1
        self.send({"jsonrpc": "2.0", "id": self.id, "method": method, "params": params or {}})
        end = time.time() + timeout
        while time.time() < end:
            try:
                m = self.inbox.get(timeout=max(0.05, end - time.time()))
            except Q.Empty:
                break
            if m is None:
                raise RuntimeError("server closed")
            if m.get("id") == self.id:
                if "error" in m:
                    raise RuntimeError(str(m["error"])[:200])
                return m["result"]
        raise RuntimeError("timeout " + method)

    def init(self):
        r = self.req("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return r

    def tool(self, name, args):
        r = self.req("tools/call", {"name": name, "arguments": args})
        if r.get("isError"):
            raise RuntimeError(f"{name}: " + str(r.get("content"))[:200])
        return r

    def alive(self):
        return self.p.poll() is None

    def kill(self):
        try:
            os.killpg(self.p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.p.wait()
        time.sleep(0.5)

    def unread(self):
        sc = self.tool("get_updates", {"format": "json", "limit": 50})["structuredContent"]
        more = sc.get("more") or 0
        return len(sc.get("items", [])) + (more if isinstance(more, int) and not isinstance(more, bool) else 0)


def wait_socket(n=1, s=30):
    end = time.time() + s
    while time.time() < end:
        with World.lock:
            if len(World.sockets) >= n:
                return True
        time.sleep(0.05)
    return False


def wait_unread(srv, want, s=15):
    end = time.time() + s
    n = -1
    while time.time() < end:
        n = srv.unread()
        if n >= want:
            return n
        time.sleep(0.2)
    return n


class MiniQueue:
    """A minimal external queue: one row per URI, committed before any ack."""
    def __init__(self, path):
        self.db = sqlite3.connect(path, isolation_level=None)
        self.db.execute("CREATE TABLE IF NOT EXISTS q(uri TEXT PRIMARY KEY, seen INTEGER NOT NULL DEFAULT 1)")

    def intake(self, call):
        stored = 0
        for _ in range(20):
            page = call("get_updates", {"format": "json", "limit": 50})["structuredContent"]
            through, blocked, rows = None, False, []
            for u in page["items"]:
                if u.get("kind") == "not_read":
                    blocked = True
                    break
                rows.append(u["uri"])
                through = u["seq"]
            self.db.execute("BEGIN IMMEDIATE")
            for r in rows:
                stored += self.db.execute("INSERT OR IGNORE INTO q(uri) VALUES(?)", (r,)).rowcount
            self.db.execute("COMMIT")
            if through is not None:
                call("ack_updates", {"through": through})
            if blocked or not page.get("more"):
                break
        return stored

    def count(self):
        return self.db.execute("SELECT count(*) FROM q").fetchone()[0]


def make_queue(path):
    if os.environ.get("BRIDGE_ADAPTER"):
        import importlib.machinery as M, importlib.util as U
        sp = U.spec_from_loader("bridge_adapter", M.SourceFileLoader("bridge_adapter", os.environ["BRIDGE_ADAPTER"]))
        m = U.module_from_spec(sp)
        sp.loader.exec_module(m)
        return m.Adapter(path)
    return MiniQueue(path)


class Crash(Exception):
    pass


def main():
    os.makedirs(WORK, exist_ok=True)
    h = Threaded(("127.0.0.1", 0), Http)
    threading.Thread(target=h.serve_forever, daemon=True).start()
    ws = socket.socket()
    ws.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ws.bind(("127.0.0.1", 0))
    ws.listen(16)
    threading.Thread(target=ws_serve, args=(ws,), daemon=True).start()
    ports = (h.server_address[1], ws.getsockname()[1])
    st = lambda name: os.path.join(WORK, name + "-" + str(time.time_ns()))

    base = int(time.time())  # as the kit's H6: stamps just after the listener begins
    iso = lambda t, frac="000": dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + frac + "Z"
    cases = [  # offsets (s, fraction) of A and B after each case's own start
        ("H7 same time for A and B", (5, "000"), (5, "000"), False),
        ("H8 A 1 ms after B", (5, "001"), (5, "000"), False),
        ("H9 A 1 ms before B", (5, "000"), (5, "001"), False),
        ("H10 B to the microsecond, A later", (5, "009"), (5, "000400"), False),
        ("H11 both acknowledged", (5, "000"), (5, "001"), True),
    ]
    for k, (name, ao, bo, both) in enumerate(cases):
        base = int(time.time())
        a_at, b_at = iso(base + ao[0], ao[1]), iso(base + bo[0], bo[1])
        World.notifs.clear(); World.seen.clear(); World.sockets.clear()
        srv = Server(ports, st(f"h6x-{k}"))
        srv.init()
        wait_socket()
        a = f"at://{sender(910 + 2 * k)}/app.bsky.feed.post/{tid(1, base - 2)}"
        b = f"at://{sender(911 + 2 * k)}/app.bsky.feed.post/{tid(2, base - 1)}"
        for uri, at in ((a, a_at), (b, b_at)):
            World.posts[uri] = "a synthetic reply"
            did = uri.split("/")[2]
            World.notifs.append({"uri": uri, "cid": "bafyfixture", "author": {"did": did, "handle": f"u{did[-6:]}.test"}, "reason": "reply",
                                 "record": {"$type": "app.bsky.feed.post", "text": "a synthetic reply", "createdAt": at}, "isRead": False, "indexedAt": at})
        got = wait_unread(srv, 2, 80)
        items = srv.tool("get_updates", {"format": "json", "limit": 50})["structuredContent"]["items"]
        pick = [u for u in items if u["uri"] in ((a, b) if both else (a,))]
        if got >= 2 and pick:
            srv.tool("ack_updates", {"through": max(u["seq"] for u in pick), "listener": "references"})
            time.sleep(0.5)
            sent = World.seen[-1] if World.seen else None
            report(f"{name}: A {a_at[11:]} B {b_at[11:]}: seenAt sent / B still unread (strictly before B) / A now read (strictly after A)",
                   (sent and sent[11:], None if both else (sent is None or sent < b_at), sent is not None and sent > a_at))
        else:
            report(name, ("not reached", got))
        srv.kill()
    print("DONE", flush=True)
    os._exit(0)


if __name__ == "__main__":
    main()
