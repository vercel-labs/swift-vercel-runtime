#!/usr/bin/env python3
"""Emulates the Vercel functions runtime for an `executable` function and checks the contract.

Mirrors what rusty-runtime does on provided.al2023 (vercel/functions,
packages/rusty-runtime-nodejs/crates/rusty_runtime/src/child):

- reads the handler from the function's .vc-config.json (the VercelBootstrap binary, which runs
  the app),
- listens on a Unix socket and spawns the handler with a cleared env plus VERCEL_IPC_PATH,
- requires the first NUL-terminated JSON message to be `server-started` (or
  `unrecoverable-error`),
- decodes every message with the same strict schema (unknown types or wrongly typed fields
  are fatal there),
- proxies requests to 127.0.0.1:<httpPort> with x-vercel-internal-* headers and expects one
  `end` message per request, with no IPC traffic for /_vercel/ping,
- sends `approaching-timeout` like the runtime does shortly before a request's deadline,
- sends `x-vercel-internal-deadline` with every request, like the runtime,
- accepts `metric` messages of type `fetch-metric` (Observability: External APIs) with their exact
  field names and JSON types,
- rejects `log` and `metric` messages for a request that already got its `end`.

The example apps implement the same routes, so every framework is checked the same way.

Usage: fake-runtime.py [--websocket] [--minimal] [--runtime-cache] [--vercel-modules]
                       /path/to/functions/index.func

--minimal skips the checks for the optional VercelRuntime features (per-request logs,
waitUntil, request helpers), for apps without any Vercel code.
--runtime-cache checks the Runtime Cache routes (/cache/:key, /cache-expire/:tag): the in-memory
fallback, and a stub of Vercel's cache service on 127.0.0.1 passed with the request as
x-vercel-sc-* headers, visible to the app or hidden by the bootstrap.
--vercel-modules adds smoke checks for the other feature modules' example routes (OIDC claims,
Global Config without EDGE_CONFIG).
Python 3.9 compatible (the amazonlinux:2023 image).
"""

import base64
import concurrent.futures
import hashlib
import http.server
import json
import os
import queue
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

KNOWN_TYPES = {
    "server-started", "metric", "custom-metric", "log", "body-end", "end",
    "bytecode", "otel-spans", "handler-started", "unrecoverable-error",
}
LOG_LEVELS = {"trace", "debug", "info", "warn", "error", "fatal"}
U32_MAX = 2**32 - 1
U64_MAX = 2**64 - 1
# The `fetch-metric` payload, as sent by the Node.js and Python runtimes.
FETCH_METRIC_FIELDS = {
    "pathname": str, "search": str, "start": int, "duration": int, "host": str,
    "statusCode": int, "method": str, "id": int,
}
CRON_SECRET = "test-cron-secret"
# The Runtime Cache credentials the harness hands the app. They must never come back in a response.
RUNTIME_CACHE_AUTHORIZATION = "Bearer test-sc"


class ContractError(Exception):
    pass


def check(condition, message):
    if not condition:
        raise ContractError(message)


def is_uint(value, maximum):
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= maximum


def validate(message):
    """Strict schema check matching rusty_runtime::child::messages::ChildToParentMessage."""
    check(isinstance(message, dict), "message is not an object: %r" % (message,))
    kind = message.get("type")
    check(kind in KNOWN_TYPES, "unknown message type: %r" % (kind,))
    payload = message.get("payload")
    check(isinstance(payload, dict), "missing payload: %r" % (message,))
    if kind == "server-started":
        check(is_uint(payload.get("initDuration"), 2**64 - 1), "bad initDuration: %r" % (payload,))
        check(is_uint(payload.get("httpPort"), 65535), "bad httpPort: %r" % (payload,))
    if kind in ("end", "body-end", "log", "metric", "handler-started"):
        context = payload.get("context")
        check(isinstance(context, dict), "missing context: %r" % (message,))
        check(isinstance(context.get("invocationId"), str), "bad invocationId: %r" % (context,))
        request_id = context.get("requestId")
        check(request_id is None or is_uint(request_id, U32_MAX), "bad requestId: %r" % (context,))
    if kind in ("end", "body-end"):
        error = payload.get("error")
        check(error is None or isinstance(error, str), "error must be string or null: %r" % (payload,))
    if kind == "log":
        check(isinstance(payload.get("message"), str), "log message must be a string: %r" % (payload,))
        base64.b64decode(payload["message"], validate=True)
        level, stream = payload.get("level"), payload.get("stream")
        check(level in LOG_LEVELS or stream in ("stdout", "stderr"), "bad log level/stream: %r" % (payload,))
    if kind == "unrecoverable-error":
        check(isinstance(payload.get("exitCode"), int), "bad exitCode: %r" % (payload,))
    if kind == "metric":
        check(set(payload) == {"context", "type", "payload"}, "bad metric keys: %r" % (payload,))
        check(payload["type"] == "fetch-metric", "unsupported metric type: %r" % (payload,))
        metric = payload["payload"]
        check(isinstance(metric, dict) and set(metric) == set(FETCH_METRIC_FIELDS), "bad fetch-metric fields: %r" % (metric,))
        for name, expected in FETCH_METRIC_FIELDS.items():
            if expected is int:
                check(is_uint(metric[name], U64_MAX), "fetch-metric %s must be a non-negative integer: %r" % (name, metric))
            else:
                check(isinstance(metric[name], str), "fetch-metric %s must be a string: %r" % (name, metric))
        check(not metric["search"].startswith("?"), "fetch-metric search must not start with ?: %r" % (metric,))


def rfc3339(timestamp):
    """Formats a Unix timestamp like the runtime's x-vercel-internal-deadline."""
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(timestamp)) + ".%03dZ" % (int(timestamp * 1000) % 1000)


def runtime_cache_key_hash(key):
    """The default Runtime Cache key hash (djb2 over UTF-16 code units with JavaScript's 32-bit
    integer semantics), like `getCache()` in @vercel/functions and RuntimeCache.defaultKeyHash."""
    def int32(value):
        value &= 0xFFFFFFFF
        return value - 2**32 if value >= 2**31 else value
    encoded = key.encode("utf-16-le")
    value = 5381
    for index in range(0, len(encoded), 2):
        value = int32(int32(value * 33) ^ (encoded[index] | encoded[index + 1] << 8))
    return format(value & 0xFFFFFFFF, "x")


class StubRuntimeCache:
    """A stand-in for Vercel's Runtime Cache service (suspense-cache API) on 127.0.0.1.

    Records every request and implements get/set/delete/revalidate with tags, answering gets
    with `x-vercel-cache-state: fresh` like the real service.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.requests = []   # (method, path, {lowercased header: value}, body)
        self.entries = {}    # path -> (body, tags)
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def _body(self):
                if self.headers.get("transfer-encoding", "").lower() == "chunked":
                    body = b""
                    while True:
                        size = int(self.rfile.readline().split(b";")[0], 16)
                        chunk = self.rfile.read(size + 2)[:size]
                        if size == 0:
                            return body
                        body += chunk
                return self.rfile.read(int(self.headers.get("content-length") or 0))

            def _handle(self):
                body = self._body()
                headers = {name.lower(): value for name, value in self.headers.items()}
                status, response_headers, response = stub.handle(self.command, self.path, headers, body)
                self.send_response(status)
                for name, value in response_headers.items():
                    self.send_header(name, value)
                self.send_header("content-length", str(len(response)))
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(response)

            do_GET = do_POST = do_DELETE = do_PUT = do_HEAD = _handle

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def handle(self, method, path, headers, body):
        with self.lock:
            self.requests.append((method, path, headers, body))
            parsed = urllib.parse.urlsplit(path)
            if parsed.path.endswith("/v1/suspense-cache/revalidate") and method == "POST":
                tags = set(urllib.parse.parse_qs(parsed.query).get("tags", [""])[0].split(","))
                self.entries = {key: entry for key, entry in self.entries.items() if not tags & entry[1]}
                return 200, {}, b""
            if method == "GET":
                if path not in self.entries:
                    return 404, {}, b""
                return 200, {"x-vercel-cache-state": "fresh", "content-type": "application/json"}, self.entries[path][0]
            if method == "POST":
                tags = set(filter(None, headers.get("x-vercel-cache-tags", "").split(",")))
                self.entries[path] = (body, tags)
                return 200, {}, b""
            if method == "DELETE":
                self.entries.pop(path, None)
                return 200, {}, b""
            return 405, {}, b""

    def take_requests(self):
        with self.lock:
            requests, self.requests = self.requests, []
            return requests


WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WebSocketClient:
    """Minimal RFC 6455 client: HTTP/1.1 upgrade on a plain TCP connection, like the runtime's
    proxy, then masked client frames."""

    def __init__(self, port, path, headers):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            "GET %s HTTP/1.1" % path,
            "Host: 127.0.0.1:%d" % port,
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: " + key,
            "Sec-WebSocket-Version: 13",
        ] + ["%s: %s" % item for item in headers.items()]
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(4096)
            check(chunk, "connection closed during the upgrade handshake")
            data += chunk
        head, self.buffer = data.split(b"\r\n\r\n", 1)
        status_line, *header_lines = head.decode("latin-1").split("\r\n")
        self.status = int(status_line.split(" ")[1])
        self.headers = {}
        for line in header_lines:
            name, _, value = line.partition(":")
            self.headers[name.strip().lower()] = value.strip()
        self.expected_accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()

    def send(self, opcode, payload):
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = bytes([0x80 | opcode, 0x80 | length])
        elif length < 65536:
            header = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack(">H", length)
        else:
            header = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack(">Q", length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            check(chunk, "WebSocket closed unexpectedly")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def recv(self):
        """Next data or close frame; answers pings."""
        while True:
            first, second = self._read(2)
            opcode, length = first & 0x0F, second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if second & 0x80 else None
            payload = self._read(length)
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            if opcode == 0x9:
                self.send(0xA, payload)
                continue
            return opcode, payload

    def close(self):
        self.send(0x8, struct.pack(">H", 1000))
        opcode, payload = self.recv()
        self.sock.close()
        return opcode, payload


class Runtime:
    def __init__(self, function_directory, name="runtime"):
        function_directory = os.path.abspath(function_directory)
        with open(os.path.join(function_directory, ".vc-config.json")) as config:
            handler = json.load(config)["handler"]
        self.executable = os.path.join(function_directory, handler)
        self.socket_path = "/tmp/vercel-%s-%d.sock" % (name, os.getpid())
        self.messages = queue.Queue()
        self.lock = threading.Condition()
        self.ends = {}      # (invocationId, requestId) -> count
        self.end_times = {}  # (invocationId, requestId) -> monotonic time of first end
        self.logs = {}      # (invocationId, requestId) -> [(level, text, monotonic time)]
        self.metrics = {}   # (invocationId, requestId) -> [fetch-metric payload]
        self.after_end = []  # (message type, (invocationId, requestId)) of logs/metrics after end
        self.stdout_lines = []
        self.other_messages = []
        self.connection = None
        self.process = None
        self.port = None

    def start(self):
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket_path)
        listener.listen(1)
        listener.settimeout(10)

        env = {
            "VERCEL_IPC_PATH": self.socket_path,
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "VERCEL": "1",
            "VERCEL_ENV": "preview",
            "VERCEL_REGION": "dev1",
            "CRON_SECRET": CRON_SECRET,
            # Users can set these as project env vars. The bootstrap must still report its own
            # ephemeral port, and gives the app a PORT of its own.
            "PORT": "9999",
            "HOSTNAME": "0.0.0.0",
        }
        started = time.monotonic()
        self.process = subprocess.Popen(
            [self.executable], env=env, cwd=os.path.dirname(self.executable),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        threading.Thread(target=self._pump_stdout, daemon=True).start()

        self.connection, _ = listener.accept()
        listener.close()
        threading.Thread(target=self._read_messages, daemon=True).start()

        first = self.messages.get(timeout=10)
        if first.get("type") == "unrecoverable-error":
            raise ContractError("child reported unrecoverable error: %r" % (first,))
        check(first.get("type") == "server-started", "first message must be server-started, got %r" % (first,))
        self.port = first["payload"]["httpPort"]
        check(self.port not in (0, 9999), "server must bind an ephemeral port, got %r" % (self.port,))
        print("server-started: port=%d initDuration=%dms spawn-to-ready=%dms" % (
            self.port, first["payload"]["initDuration"], (time.monotonic() - started) * 1000))
        threading.Thread(target=self._dispatch, daemon=True).start()

    def _pump_stdout(self):
        for line in self.process.stdout:
            text = line.decode("utf-8", "replace")
            self.stdout_lines.append(text)
            sys.stdout.write("  [app] " + text)
            sys.stdout.flush()

    def _read_messages(self):
        buffer = b""
        while True:
            chunk = self.connection.recv(65536)
            if not chunk:
                return
            buffer += chunk
            while b"\0" in buffer:
                frame, buffer = buffer.split(b"\0", 1)
                message = json.loads(frame.decode("utf-8"))
                validate(message)
                self.messages.put(message)

    def _dispatch(self):
        while True:
            message = self.messages.get()
            now = time.monotonic()
            payload = message["payload"]
            with self.lock:
                if message["type"] == "end":
                    key = (payload["context"]["invocationId"], payload["context"]["requestId"])
                    self.ends[key] = self.ends.get(key, 0) + 1
                    self.end_times.setdefault(key, now)
                elif message["type"] == "log":
                    key = (payload["context"]["invocationId"], payload["context"]["requestId"])
                    if key in self.ends:
                        self.after_end.append(("log", key))
                    text = base64.b64decode(payload["message"]).decode("utf-8", "replace")
                    self.logs.setdefault(key, []).append((payload.get("level"), text, now))
                elif message["type"] == "metric":
                    key = (payload["context"]["invocationId"], payload["context"]["requestId"])
                    if key in self.ends:
                        self.after_end.append(("metric", key))
                    self.metrics.setdefault(key, []).append(payload["payload"])
                else:
                    self.other_messages.append(message)
                self.lock.notify_all()

    def send(self, message):
        self.connection.sendall(json.dumps(message).encode() + b"\0")

    def wait_for_end(self, invocation_id, request_id, timeout=3.0):
        deadline = time.monotonic() + timeout
        key = (invocation_id, request_id)
        with self.lock:
            while self.ends.get(key, 0) == 0:
                remaining = deadline - time.monotonic()
                check(remaining > 0, "no end message for %r" % (key,))
                self.lock.wait(remaining)
            return self.ends[key]

    def logs_for(self, invocation_id, request_id):
        with self.lock:
            return list(self.logs.get((invocation_id, request_id), []))

    def metrics_for(self, invocation_id, request_id):
        with self.lock:
            return list(self.metrics.get((invocation_id, request_id), []))

    def request(self, path, invocation_id=None, request_id=None, extra_headers=None, method=None):
        headers = dict(extra_headers or {})
        if invocation_id is not None:
            headers["x-vercel-internal-invocation-id"] = invocation_id
            headers["x-vercel-internal-request-id"] = str(request_id)
            headers["x-vercel-internal-trace-id"] = "trace-1"
            headers["x-vercel-internal-span-id"] = "span-1"
            headers.setdefault("x-vercel-internal-deadline", rfc3339(time.time() + 60))
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def app_pid(self):
        """The app process the bootstrap started (from any of its threads)."""
        pids = []
        tasks = "/proc/%d/task" % self.process.pid
        for task in os.listdir(tasks):
            with open(os.path.join(tasks, task, "children")) as children:
                pids += [int(pid) for pid in children.read().split()]
        check(len(pids) == 1, "expected one app process, got %r" % pids)
        return pids[0]

    def wait_for_message(self, kind, timeout=5.0):
        deadline = time.monotonic() + timeout
        with self.lock:
            while True:
                for message in self.other_messages:
                    if message["type"] == kind:
                        return message
                remaining = deadline - time.monotonic()
                check(remaining > 0, "no %s message" % kind)
                self.lock.wait(remaining)

    def stop(self):
        self.process.send_signal(signal.SIGTERM)
        try:
            return self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            raise ContractError("process did not exit within 10s of SIGTERM")


def main():
    flags = ("--websocket", "--minimal", "--runtime-cache", "--vercel-modules")
    arguments = [argument for argument in sys.argv[1:] if argument not in flags]
    websocket = "--websocket" in sys.argv[1:]
    minimal = "--minimal" in sys.argv[1:]
    runtime_cache = "--runtime-cache" in sys.argv[1:]
    vercel_modules = "--vercel-modules" in sys.argv[1:]
    if len(arguments) != 1:
        print(__doc__)
        return 2
    runtime = Runtime(arguments[0])
    results = []

    def test(name):
        def decorator(fn):
            try:
                fn()
                results.append((name, None))
                print("PASS  %s" % name)
            except Exception as error:  # noqa: BLE001
                results.append((name, error))
                print("FAIL  %s: %s" % (name, error))
            return fn
        return decorator

    runtime.start()

    @test("ping returns 200 without IPC traffic")
    def _():
        with runtime.lock:
            before = len(runtime.ends) + len(runtime.logs) + len(runtime.other_messages)
        status, body = runtime.request("/_vercel/ping")
        check(status == 200, "status %r" % status)
        check(body == b"OK", "body %r" % body)
        time.sleep(0.3)
        with runtime.lock:
            after = len(runtime.ends) + len(runtime.logs) + len(runtime.other_messages)
        check(after == before, "ping produced IPC messages")

    @test("the app gets its own PORT and bootstrap socket, not the runtime's IPC socket")
    def _():
        with open("/proc/%d/environ" % runtime.app_pid(), "rb") as environ:
            variables = dict(entry.split(b"=", 1) for entry in environ.read().split(b"\0") if b"=" in entry)
        check(b"VERCEL_IPC_PATH" not in variables, "the app must not see VERCEL_IPC_PATH")
        check(variables.get(b"PORT") not in (None, b"9999"), "PORT %r" % variables.get(b"PORT"))
        check(variables.get(b"VERCEL_BOOTSTRAP_SOCKET"), "missing VERCEL_BOOTSTRAP_SOCKET")
        check(variables.get(b"VERCEL_REGION") == b"dev1", "project env vars must reach the app")

    @test("GET / sends end with matching context")
    def _():
        status, body = runtime.request("/", "inv-a", 1)
        check(status == 200, "status %r" % status)
        check(b"running natively on Vercel" in body, "body %r" % body)
        check(runtime.wait_for_end("inv-a", 1) == 1, "expected exactly one end")

    @test("internal headers are stripped, OIDC token and deadline exposed")
    def _():
        status, body = runtime.request(
            "/headers", "inv-a", 2, {"x-vercel-internal-oidc-token": "oidc-123", "x-vercel-deadline": "spoofed"})
        check(status == 200, "status %r" % status)
        names = json.loads(body)
        leaked = [name for name in names if name.startswith("x-vercel-internal-")]
        check(not leaked, "leaked internal headers: %r" % leaked)
        check("x-vercel-oidc-token" in names, "missing x-vercel-oidc-token in %r" % names)
        check(names.count("x-vercel-bootstrap-request") == 1, "expected one bootstrap token in %r" % names)
        check(names.count("x-vercel-deadline") == 1, "expected one x-vercel-deadline in %r" % names)
        runtime.wait_for_end("inv-a", 2)

    @test("runtime cache headers follow the no-leak rules")
    def _():
        cache_headers = {"x-vercel-sc-runtime-cache": "1", "x-vercel-sc-host": "cache.internal"}
        status, body = runtime.request("/headers", "inv-sc", 1, cache_headers)
        check(status == 200, "status %r" % status)
        names = json.loads(body)
        check("x-vercel-sc-runtime-cache" not in names, "runtime cache header leaked: %r" % names)
        check("x-vercel-sc-host" in names, "sc-host should pass through without no-leak: %r" % names)

        hidden = dict(cache_headers, **{"x-vercel-sc-no-header-leak": "1"})
        status, body = runtime.request("/headers", "inv-sc", 2, hidden)
        names = json.loads(body)
        leaked = [name for name in names if name.startswith("x-vercel-sc-")]
        check(not leaked, "sc headers leaked despite no-leak: %r" % leaked)
        runtime.wait_for_end("inv-sc", 1)
        runtime.wait_for_end("inv-sc", 2)

    if not minimal:
        @test("JSON route")
        def _():
            status, body = runtime.request("/json", "inv-a", 3)
            check(status == 200, "status %r" % status)
            payload = json.loads(body)
            check(payload.get("region") == "dev1", "payload %r" % payload)
            runtime.wait_for_end("inv-a", 3)

    if not minimal:
        @test("the deadline reaches the app as x-vercel-deadline, replacing client values")
        def _():
            # 2026-10-11T17:00:00.123Z, with an offset and extra digits that are truncated.
            deadline = "2026-10-11T19:00:00.1239+02:00"
            status, body = runtime.request("/request-context", "inv-deadline", 1, {
                "x-vercel-internal-deadline": deadline, "x-vercel-deadline": "spoofed"})
            check(status == 200, "status %r" % status)
            payload = json.loads(body)
            check(payload.get("deadline") == deadline, "x-vercel-deadline %r" % payload.get("deadline"))
            check(payload.get("deadlineMilliseconds") == 1791738000123, "Vercel.deadline %r" % payload.get("deadlineMilliseconds"))
            check(payload["headers"].count("x-vercel-deadline") == 1, "headers %r" % payload["headers"])
            runtime.wait_for_end("inv-deadline", 1)

        @test("fetch metrics are reported for their request")
        def _():
            started = int(time.time() * 1000)
            status, body = runtime.request("/fetch-metric", "inv-metric", 1)
            finished = int(time.time() * 1000)
            check(status == 200 and body == b"reported\n", "status %r body %r" % (status, body))
            runtime.wait_for_end("inv-metric", 1)
            # The app sends the metric before releasing the request, so it arrives before end.
            metrics = runtime.metrics_for("inv-metric", 1)
            check(len(metrics) == 1, "expected one fetch-metric, got %r" % metrics)
            metric = metrics[0]
            expected = {"pathname": "/v1/x", "search": "a=1", "host": "example.com", "method": "GET",
                        "statusCode": 200, "duration": 45}
            check(all(metric[key] == value for key, value in expected.items()), "metric %r" % metric)
            check(metric["id"] >= 1, "id %r" % metric["id"])
            check(started - 45 - 1000 <= metric["start"] <= finished, "start %r not within [%r, %r]" % (metric["start"], started - 45, finished))

            # Ids increment per process.
            runtime.request("/fetch-metric", "inv-metric", 2)
            runtime.wait_for_end("inv-metric", 2)
            second = runtime.metrics_for("inv-metric", 2)
            check(len(second) == 1 and second[0]["id"] > metric["id"], "second metric %r" % second)

    if runtime_cache:
        stub = StubRuntimeCache()

        def cache_call(path, invocation_id, request_id, headers=None, method=None):
            status, body = runtime.request(path, invocation_id, request_id, headers, method=method)
            check(status == 200, "%s status %r" % (path, status))
            runtime.wait_for_end(invocation_id, request_id)
            check(RUNTIME_CACHE_AUTHORIZATION.split(" ")[1].encode() not in body,
                  "%s returned the cache credentials: %r" % (path, body))
            payload = json.loads(body)
            check("error" not in payload, "%s error %r" % (path, payload))
            return payload

        @test("Runtime Cache: set, get and expireTag with the in-memory fallback")
        def _():
            stub.take_requests()
            check(cache_call("/cache/harness", "inv-cache", 1).get("hit") is False, "expected a miss before set")
            stored = cache_call("/cache/harness?value=hello%20swift&ttl=60&tags=t1,t2", "inv-cache", 2, method="PUT")
            check(stored.get("value") == "hello swift" and stored.get("tags") == ["t1", "t2"], "set %r" % stored)
            found = cache_call("/cache/harness", "inv-cache", 3)
            check(found.get("hit") is True and found.get("value") == "hello swift", "get %r" % found)
            cache_call("/cache-expire/t2", "inv-cache", 4, method="POST")
            check(cache_call("/cache/harness", "inv-cache", 5).get("hit") is False, "expected a miss after expireTag")
            # No cache configuration with the requests: nothing may reach a cache service.
            check(not stub.take_requests(), "the in-memory fallback contacted the cache service")

        def check_cache_service(hidden):
            invocation_id = "inv-sc-hidden" if hidden else "inv-sc-visible"
            key = "harness-hidden" if hidden else "harness-visible"
            configuration = {
                "x-vercel-sc-host": "127.0.0.1:%d" % stub.port,
                "x-vercel-sc-protocol": "http",
                "x-vercel-sc-basepath": "/base",
                "x-vercel-sc-headers": json.dumps({"authorization": RUNTIME_CACHE_AUTHORIZATION}),
            }
            if hidden:
                configuration.update({"x-vercel-sc-no-header-leak": "1", "x-vercel-sc-runtime-cache": "1"})

            # Which x-vercel-sc-* headers the app sees (names only).
            payload = cache_call("/request-context", invocation_id, 1, configuration)
            visible = sorted(name for name in payload["headers"] if name.startswith("x-vercel-sc-"))
            if hidden:
                check(not visible, "sc headers leaked despite no-leak: %r" % visible)
            else:
                expected = sorted(name for name in configuration if name != "x-vercel-sc-runtime-cache")
                check(visible == expected, "visible sc headers %r, expected %r" % (visible, expected))

            prefix = "/base/v1/suspense-cache/"
            suffix = "$" + runtime_cache_key_hash(key)
            stub.take_requests()

            def one_request(method, label):
                requests = stub.take_requests()
                check(len(requests) == 1, "%s: expected one cache request, got %r" % (label, requests))
                request_method, path, headers, body = requests[0]
                check(request_method == method, "%s: method %r" % (label, request_method))
                check(headers.get("authorization") == RUNTIME_CACHE_AUTHORIZATION, "%s: authorization %r" % (label, headers))
                for name in ("x-vercel-internal-sc-client-origin", "x-vercel-internal-sc-client-name"):
                    check(headers.get(name) == "RUNTIME_CACHE", "%s: %s %r" % (label, name, headers.get(name)))
                return path, headers, body

            def entry_path(path, label):
                check(path.startswith(prefix) and path.endswith(suffix) and "/" not in path[len(prefix):],
                      "%s: path %r, expected %s<namespace>%s" % (label, path, prefix, suffix))

            check(cache_call("/cache/%s" % key, invocation_id, 2, configuration).get("hit") is False, "expected a miss")
            path, _, _ = one_request("GET", "get")
            entry_path(path, "get")
            metrics = runtime.metrics_for(invocation_id, 2)
            check(any(metric["host"] == "127.0.0.1:%d" % stub.port and metric["pathname"] == path and metric["statusCode"] == 404
                      for metric in metrics), "no fetch-metric for the cache request: %r" % metrics)

            stored = cache_call("/cache/%s?value=hello%%20swift&ttl=60&tags=t1,t2" % key, invocation_id, 3, configuration, method="PUT")
            check(stored.get("value") == "hello swift", "set %r" % stored)
            path, headers, body = one_request("POST", "set")
            entry_path(path, "set")
            check(json.loads(body) == "hello swift", "set body %r" % body)
            check(headers.get("x-vercel-revalidate") == "60", "set ttl %r" % headers)
            check(headers.get("x-vercel-cache-tags") == "t1,t2", "set tags %r" % headers)
            check(headers.get("x-vercel-cache-item-name") == key, "set name %r" % headers)

            found = cache_call("/cache/%s" % key, invocation_id, 4, configuration)
            check(found.get("hit") is True and found.get("value") == "hello swift", "get after set %r" % found)
            one_request("GET", "get after set")

            cache_call("/cache-expire/t2", invocation_id, 5, configuration, method="POST")
            path, _, _ = one_request("POST", "expireTag")
            check(path == prefix + "revalidate?tags=t2", "expireTag path %r" % path)

            check(cache_call("/cache/%s" % key, invocation_id, 6, configuration).get("hit") is False, "expected a miss after expireTag")
            one_request("GET", "get after expireTag")

        @test("Runtime Cache: uses Vercel's cache service from visible x-vercel-sc-* headers")
        def _():
            check_cache_service(hidden=False)

        @test("Runtime Cache: uses Vercel's cache service when the bootstrap hides x-vercel-sc-* headers")
        def _():
            check_cache_service(hidden=True)

    if vercel_modules:
        @test("OIDC: token claims from the request, never the token")
        def _():
            def segment(value):
                return base64.urlsafe_b64encode(json.dumps(value).encode()).rstrip(b"=").decode()
            token = "%s.%s.signature" % (segment({"alg": "RS256"}), segment({
                "iss": "https://oidc.vercel.com/acme", "sub": "owner:acme:project:hello:environment:preview",
                "aud": "https://vercel.com/acme", "exp": 4102444800, "project_id": "prj_1", "environment": "preview"}))
            status, body = runtime.request("/oidc", "inv-oidc", 1, {"x-vercel-internal-oidc-token": token})
            check(status == 200, "status %r" % status)
            check(token.encode() not in body, "the token must not be returned")
            payload = json.loads(body)
            check(payload.get("source") == "request", "source %r" % payload)
            check(payload.get("issuer") == "https://oidc.vercel.com/acme", "issuer %r" % payload)
            check(payload.get("audience") == ["https://vercel.com/acme"], "audience %r" % payload)
            check(payload.get("expiresAt") == 4102444800 and payload.get("expired") is False, "expiry %r" % payload)
            check(payload.get("projectID") == "prj_1" and payload.get("environment") == "preview", "claims %r" % payload)
            runtime.wait_for_end("inv-oidc", 1)

        @test("Global Config: reports a missing EDGE_CONFIG instead of failing")
        def _():
            status, body = runtime.request("/global-config/flag", "inv-gc", 1)
            check(status == 200, "status %r" % status)
            check("EDGE_CONFIG is not set" in json.loads(body).get("error", ""), "payload %r" % body)
            runtime.wait_for_end("inv-gc", 1)

    @test("404 still sends end")
    def _():
        status, _ = runtime.request("/does-not-exist", "inv-a", 4)
        check(status == 404, "status %r" % status)
        runtime.wait_for_end("inv-a", 4)

    @test("thrown error returns 500 and sends end")
    def _():
        status, _ = runtime.request("/error", "inv-a", 5)
        check(status == 500, "status %r" % status)
        runtime.wait_for_end("inv-a", 5)

    @test("streaming response delivers chunks as they are written")
    def _():
        started = time.monotonic()
        req = urllib.request.Request("http://127.0.0.1:%d/stream" % runtime.port, headers={
            "x-vercel-internal-invocation-id": "inv-a", "x-vercel-internal-request-id": "6"})
        with urllib.request.urlopen(req, timeout=10) as response:
            check(response.status == 200, "status %r" % response.status)
            first = response.readline()
            first_at = time.monotonic() - started
            body = first + response.read()
        check(body == b"".join(b"chunk %d\n" % i for i in range(1, 6)), "body %r" % body)
        check(first_at < 0.5, "first chunk arrived after %.2fs: the response was buffered" % first_at)
        check(time.monotonic() - started >= 0.8, "stream finished too fast")
        runtime.wait_for_end("inv-a", 6)

    if not minimal:
        @test("logs are attributed to the request with their level")
        def _():
            status, _ = runtime.request("/log", "inv-log", 1)
            check(status == 200, "status %r" % status)
            runtime.wait_for_end("inv-log", 1)
            logs = runtime.logs_for("inv-log", 1)
            matching = [log for log in logs if "hello from swift-log" in log[1]]
            check(matching, "no IPC log for the request, got %r" % logs)
            check(matching[0][0] == "warn", "expected level warn, got %r" % matching[0][0])
            check("route=log" in matching[0][1], "metadata missing: %r" % matching[0][1])
            check(not any("hello from swift-log" in line for line in runtime.stdout_lines),
                  "request log was also written to stdout")

        @test("waitUntil responds immediately and delays end")
        def _():
            started = time.monotonic()
            status, body = runtime.request("/wait-until/700", "inv-wait", 1)
            responded = time.monotonic()
            check(status == 200 and body == b"scheduled\n", "status %r body %r" % (status, body))
            check(responded - started < 0.5, "response waited for background work (%.2fs)" % (responded - started))
            runtime.wait_for_end("inv-wait", 1, timeout=5)
            with runtime.lock:
                ended = runtime.end_times[("inv-wait", 1)]
            check(ended - started >= 0.65, "end sent before background work finished (%.2fs)" % (ended - started))
            done = [log for log in runtime.logs_for("inv-wait", 1) if "background work done" in log[1]]
            check(done, "background log missing or not attributed to the request")
            check(done[0][2] <= ended, "background log arrived after end")

        @test("approaching-timeout cancels waitUntil work and sends end")
        def _():
            started = time.monotonic()
            status, _ = runtime.request("/wait-until/60000", "inv-timeout", 1)
            check(status == 200, "status %r" % status)
            time.sleep(0.2)
            with runtime.lock:
                check(("inv-timeout", 1) not in runtime.ends, "end sent while background work was running")
            runtime.send({"type": "approaching-timeout", "context": {"invocationId": "inv-timeout", "requestId": 1}})
            runtime.wait_for_end("inv-timeout", 1, timeout=3)
            check(time.monotonic() - started < 5, "cancellation took too long")
            cancelled = [log for log in runtime.logs_for("inv-timeout", 1) if "background work cancelled" in log[1]]
            check(cancelled, "background work was not cancelled")

    @test("cron route requires CRON_SECRET")
    def _():
        status, body = runtime.request("/cron", "inv-cron", 1)
        check(status == 401, "unauthenticated cron returned %r" % status)
        check(json.loads(body) == {"error": "unauthorized"}, "body %r" % body)
        status, _ = runtime.request("/cron", "inv-cron", 2, {"Authorization": "Bearer wrong"})
        check(status == 401, "wrong secret returned %r" % status)
        status, body = runtime.request("/cron", "inv-cron", 3, {"Authorization": "Bearer " + CRON_SECRET})
        check(status == 200 and body == b"cron ok\n", "authorized cron returned %r %r" % (status, body))
        for request_id in (1, 2, 3):
            runtime.wait_for_end("inv-cron", request_id)

    if not minimal:
        @test("request helpers: geolocation, IP, request id, environment")
        def _():
            status, body = runtime.request("/geo", "inv-geo", 1, {
                "x-vercel-ip-city": "S%C3%A3o%20Paulo",
                "x-vercel-ip-country": "BR",
                "x-vercel-ip-country-region": "SP",
                "x-vercel-ip-latitude": "-23.5",
                "x-vercel-ip-longitude": "-46.6",
                "x-vercel-ip-postal-code": "01000",
                "x-vercel-id": "gru1::iad1::abc",
                "x-real-ip": "203.0.113.7",
            })
            check(status == 200, "status %r" % status)
            payload = json.loads(body)
            geo = payload.get("geolocation", {})
            expected = {
                "city": u"S\u00e3o Paulo", "country": "BR", "flag": u"\U0001F1E7\U0001F1F7",
                "countryRegion": "SP", "region": "gru1", "latitude": "-23.5", "longitude": "-46.6",
                "postalCode": "01000",
            }
            check(geo == expected, "geolocation %r" % geo)
            check(payload.get("ipAddress") == "203.0.113.7", "ip %r" % payload.get("ipAddress"))
            check(payload.get("id") == "gru1::iad1::abc", "id %r" % payload.get("id"))
            check(payload.get("environment") == "preview", "environment %r" % payload.get("environment"))
            check(payload.get("region") == "dev1", "region %r" % payload.get("region"))
            runtime.wait_for_end("inv-geo", 1)

    def internal_headers(invocation_id, request_id):
        return {
            "x-vercel-internal-invocation-id": invocation_id,
            "x-vercel-internal-request-id": str(request_id),
            "x-vercel-internal-trace-id": "trace-1",
        }

    if websocket:
        @test("WebSocket: end at accept, echo text and binary, clean close")
        def _():
            ws = WebSocketClient(runtime.port, "/ws", internal_headers("inv-ws", 1))
            check(ws.status == 101, "expected 101, got %r" % ws.status)
            check(ws.headers.get("sec-websocket-accept") == ws.expected_accept, "bad Sec-WebSocket-Accept")
            # The invocation ends at accept, while the socket stays open.
            runtime.wait_for_end("inv-ws", 1)
            ws.send(0x1, u"hello from Python \u2713".encode())
            check(ws.recv() == (0x1, u"hello from Python \u2713".encode()), "text echo failed")
            payload = os.urandom(10000)  # 16-bit length encoding; under the default 16 KiB frame limit
            ws.send(0x2, payload)
            check(ws.recv() == (0x2, payload), "binary echo failed")
            opcode, _ = ws.close()
            check(opcode == 0x8, "expected a close frame, got opcode %r" % opcode)
            time.sleep(0.3)
            with runtime.lock:
                check(runtime.ends[("inv-ws", 1)] == 1, "closing the socket sent another end")

        # hummingbird-websocket answers a declined upgrade itself (400) without running the HTTP
        # responder; the bootstrap must still end the invocation, exactly once.
        @test("WebSocket: declined upgrade still sends exactly one end")
        def _():
            ws = WebSocketClient(runtime.port, "/hello/upgrade", internal_headers("inv-ws", 2))
            check(ws.status == 400, "expected 400, got %r" % ws.status)
            ws.sock.close()
            runtime.wait_for_end("inv-ws", 2)
            time.sleep(0.3)
            with runtime.lock:
                check(runtime.ends[("inv-ws", 2)] == 1, "expected exactly one end")

        @test("WebSocket: 20 concurrent connections")
        def _():
            def session(index):
                ws = WebSocketClient(runtime.port, "/ws", internal_headers("inv-ws-many", index))
                check(ws.status == 101, "status %r" % ws.status)
                message = ("message %d" % index).encode()
                for _ in range(10):
                    ws.send(0x1, message)
                    check(ws.recv() == (0x1, message), "echo mismatch on %d" % index)
                ws.close()
                return index
            with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
                done = list(pool.map(session, range(20)))
            check(len(done) == 20, "sessions %r" % done)
            for index in range(20):
                check(runtime.wait_for_end("inv-ws-many", index) == 1, "end count for %d" % index)

    @test("50 concurrent requests each get one end")
    def _():
        ids = list(range(100, 150))
        with concurrent.futures.ThreadPoolExecutor(max_workers=25) as pool:
            statuses = list(pool.map(lambda i: runtime.request("/hello/n%d" % i, "inv-b", i)[0], ids))
        check(all(status == 200 for status in statuses), "statuses %r" % statuses)
        for i in ids:
            check(runtime.wait_for_end("inv-b", i) == 1, "duplicate end for %d" % i)

    @test("every log and metric belongs to a request that ended, before its end, and no unexpected messages")
    def _():
        with runtime.lock:
            orphans = [key for key in list(runtime.logs) + list(runtime.metrics) if key not in runtime.ends]
            after_end = list(runtime.after_end)
            other = list(runtime.other_messages)
        check(not orphans, "logs or metrics for requests that never ended: %r" % orphans)
        check(not after_end, "logs or metrics after their request's end: %r" % after_end)
        check(not other, "unexpected: %r" % other)

    @test("exits cleanly on SIGTERM")
    def _():
        code = runtime.stop()
        check(code == 0, "exit code %r" % code)

    @test("an app that crashes is reported as an unrecoverable error")
    def _():
        crashing = Runtime(arguments[0], name="crash")
        crashing.start()
        os.kill(crashing.app_pid(), signal.SIGKILL)
        message = crashing.wait_for_message("unrecoverable-error")
        check("exited unexpectedly" in message["payload"]["message"], "message %r" % message)
        code = crashing.process.wait(timeout=5)
        check(code == 128 + signal.SIGKILL, "exit code %r" % code)

    failed = [name for name, error in results if error]
    print("\n%d passed, %d failed" % (len(results) - len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
