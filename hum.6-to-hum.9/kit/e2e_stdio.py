#!/usr/bin/python3 -I
"""End-to-end checks of the real at_mcp-stdio binary, run inside box.sh.

Everything it talks to is local and synthetic: a fake PDS and Constellation
(HTTP), a fake Spacedust (WebSocket), a raw JSON-RPC MCP client, and an external
SQLite queue that reads with get_updates, commits, then acknowledges.

Usage (inside the sandbox): python3 -I /work/e2e_stdio.py
"""
import base64, datetime as dt, hashlib, http.server, json, os, queue as Q, signal, socket, socketserver
import sqlite3, struct, subprocess, sys, threading, time, urllib.parse

ME = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
MINE = f"at://{ME}/app.bsky.feed.post/3kmine22222a2"
ALPHA = "234567abcdefghijklmnopqrstuvwxyz"
WORK = os.environ.get("E2E_WORK", "/work/e2e")


def report(name, value):
    print(f"RESULT\t{name}\t{value!r}", flush=True)


def tid(n):
    v = ((int(time.time()) * 1_000_000 + n) << 10) | 1
    return "".join(ALPHA[(v >> (i * 5)) & 31] for i in range(12, -1, -1))


def sender(n):
    s, x = "", n
    for _ in range(24):
        s = ALPHA[x % 32] + s
        x //= 32
    return "did:plc:" + s


class World:
    posts, down, gone, bots = {}, False, set(), set()
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
            return self.out({"notifications": []})
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

    # E1: a save lands before the client has sent anything.
    srv = Server(ports, st("early"))
    up = wait_socket()
    report("E1a stream connected before any client request", up)
    reply_link(1)
    time.sleep(4)
    alive = srv.alive()
    report("E1b process alive 4 s after a save, no request sent yet", alive)
    if alive:
        try:
            srv.init()
            report("E1c update readable afterwards (expect 1)", wait_unread(srv, 1))
        except Exception as e:
            report("E1c error", str(e)[:150])
    else:
        report("E1c exit status", srv.p.returncode)
    srv.kill()
    with World.lock:
        World.sockets.clear()

    # E2: told only while subscribed.
    srv = Server(ports, st("sub"))
    srv.init()
    wait_socket()
    uri = f"atmcp://{ME}/updates"
    reply_link(2)
    time.sleep(2.5)
    told = [n for n in srv.notes if n.get("method") == "notifications/resources/updated"]
    report("E2a initialized, not subscribed: told / alive (expect 0 / True)", (len(told), srv.alive()))
    if srv.alive():
        try:
            srv.req("resources/subscribe", {"uri": uri})
            reply_link(3)
            time.sleep(2.5)
            told = [n for n in srv.notes if n.get("method") == "notifications/resources/updated"]
            report("E2b subscribed: told at least once (expect True)", len(told) >= 1)
            before = len(told)
            srv.req("resources/unsubscribe", {"uri": uri})
            reply_link(4)
            time.sleep(2.5)
            told = [n for n in srv.notes if n.get("method") == "notifications/resources/updated"]
            report("E2c after unsubscribe: new announcements (expect 0)", len(told) - before)
            report("E2d all three updates still readable (expect 3)", wait_unread(srv, 3))
        except Exception as e:
            report("E2 error", str(e)[:180])
    srv.kill()
    with World.lock:
        World.sockets.clear()

    # B: read, commit to the external queue, then acknowledge.
    def fresh(tag):
        s = st(tag)
        return Server(ports, s), s, make_queue(s + ".queue.db")

    # B1: 120 updates through pages.
    srv, s, q = fresh("b1")
    srv.init()
    wait_socket()
    for n in range(100, 220):
        reply_link(n)
        if n % 20 == 0:
            time.sleep(0.1)
    wait_unread(srv, 50)
    time.sleep(2)
    stored = q.intake(srv.tool)
    report("B1 120 live updates: stored / rows / unread after ack (expect 120 / 120 / 0)", (stored, q.count(), srv.unread()))
    srv.kill()
    with World.lock:
        World.sockets.clear()

    # B2: the consumer fails between its commit and the ack.
    srv, s, q = fresh("b2")
    srv.init()
    wait_socket()
    for n in range(300, 310):
        reply_link(n)
    wait_unread(srv, 10)
    def no_ack(t, a):
        if t == "ack_updates":
            raise Crash()
        return srv.tool(t, a)
    try:
        q.intake(no_ack)
    except Crash:
        pass
    a = (q.count(), srv.unread())
    again = q.intake(srv.tool)
    report("B2 stop between commit and ack: rows, unread / re-read adds / rows, unread (expect (10,10) / 0 / (10,0))", (a, again, (q.count(), srv.unread())))
    srv.kill()
    with World.lock:
        World.sockets.clear()

    # B3: at_mcp is killed between the consumer's commit and the ack.
    srv, s, q = fresh("b3")
    srv.init()
    wait_socket()
    for n in range(400, 410):
        reply_link(n)
    wait_unread(srv, 10)
    time.sleep(0.5)
    box = {}
    def kill_at_ack(t, a):
        if t == "ack_updates":
            srv2 = box["s"]
            srv2.kill()
            raise Crash()
        return box["s"].tool(t, a)
    box["s"] = srv
    try:
        q.intake(kill_at_ack)
    except Crash:
        pass
    rows = q.count()
    with World.lock:
        World.sockets.clear()
    srv = Server(ports, s)
    srv.init()
    wait_socket()
    un = wait_unread(srv, 10)
    again = q.intake(srv.tool)
    report("B3 kill -9 of at_mcp between commit and ack: rows / unread after restart / re-read adds / final rows, unread (expect 10 / 10 / 0 / (10,0))",
           (rows, un, again, (q.count(), srv.unread())))
    srv.kill()
    with World.lock:
        World.sockets.clear()

    # B4: a post read fails: nothing past it is acknowledged, and it comes back.
    srv, s, q = fresh("b4")
    srv.init()
    wait_socket()
    for n in range(500, 503):
        reply_link(n)
    wait_unread(srv, 3)
    World.down = True
    q.intake(srv.tool)
    a = (q.count(), srv.unread())
    World.down = False
    q.intake(srv.tool)
    report("B4 post reads failing, then back: rows, unread during / rows, unread after (expect (0,3) / (3,0))", (a, (q.count(), srv.unread())))
    srv.kill()
    with World.lock:
        World.sockets.clear()

    # B5: same URI sent twice live, and a post deleted before the read.
    srv, s, q = fresh("b5")
    srv.init()
    wait_socket()
    u = reply_link(600)
    rkey = u.rsplit("/", 1)[1]
    time.sleep(1.5)
    emit({"kind": "link", "origin": "live", "link": {"operation": "create", "source": "app.bsky.feed.post:reply.parent.uri",
                                                     "source_record": u, "source_rev": rkey, "subject": MINE}})
    gone = reply_link(601)
    time.sleep(1.5)
    World.gone.add(gone)
    un = srv.unread()
    q.intake(srv.tool)
    report("B5 duplicate live event + one deleted post: unread before / rows / unread (expect 2 / 2 / 0)", (un, q.count(), srv.unread()))
    if hasattr(q, "extra"):
        for name, value in q.extra(srv, reply_link, wait_unread):
            report(name, value)
    srv.kill()
    print("DONE", flush=True)
    os._exit(0)


if __name__ == "__main__":
    main()
