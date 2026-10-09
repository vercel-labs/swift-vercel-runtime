#!/usr/bin/env python3
"""Emulates the Vercel functions runtime for an `executable` function and checks the contract.

Mirrors what rusty-runtime does on provided.al2023 (vercel/functions,
packages/rusty-runtime-nodejs/crates/rusty_runtime/src/child):

- listens on a Unix socket and spawns the binary with a cleared env plus VERCEL_IPC_PATH,
- requires the first NUL-terminated JSON message to be `server-started` (or
  `unrecoverable-error`),
- decodes every message with the same strict schema (unknown types or wrongly typed fields
  are fatal there),
- proxies requests to 127.0.0.1:<httpPort> with x-vercel-internal-* headers and expects one
  `end` message per request, with no IPC traffic for /_vercel/ping,
- sends `approaching-timeout` like the runtime does shortly before a request's deadline.

The example apps implement the same routes, so every adapter is checked the same way.

Usage: fake-runtime.py [--websocket] /path/to/executable
Python 3.9 compatible (the amazonlinux:2023 image).
"""

import base64
import concurrent.futures
import hashlib
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
import urllib.request

KNOWN_TYPES = {
    "server-started", "metric", "custom-metric", "log", "body-end", "end",
    "bytecode", "otel-spans", "handler-started", "unrecoverable-error",
}
LOG_LEVELS = {"trace", "debug", "info", "warn", "error", "fatal"}
U32_MAX = 2**32 - 1
CRON_SECRET = "test-cron-secret"


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
    def __init__(self, executable):
        self.executable = os.path.abspath(executable)
        self.socket_path = "/tmp/vercel-%d.sock" % os.getpid()
        self.messages = queue.Queue()
        self.lock = threading.Condition()
        self.ends = {}      # (invocationId, requestId) -> count
        self.end_times = {}  # (invocationId, requestId) -> monotonic time of first end
        self.logs = {}      # (invocationId, requestId) -> [(level, text, monotonic time)]
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
            # Users can set these as project env vars; the server must still bind 127.0.0.1:0.
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
                    text = base64.b64decode(payload["message"]).decode("utf-8", "replace")
                    self.logs.setdefault(key, []).append((payload.get("level"), text, now))
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

    def request(self, path, invocation_id=None, request_id=None, extra_headers=None):
        headers = dict(extra_headers or {})
        if invocation_id is not None:
            headers["x-vercel-internal-invocation-id"] = invocation_id
            headers["x-vercel-internal-request-id"] = str(request_id)
            headers["x-vercel-internal-trace-id"] = "trace-1"
            headers["x-vercel-internal-span-id"] = "span-1"
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path), headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    def stop(self):
        self.process.send_signal(signal.SIGTERM)
        try:
            return self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            raise ContractError("process did not exit within 10s of SIGTERM")


def main():
    arguments = [argument for argument in sys.argv[1:] if argument != "--websocket"]
    websocket = "--websocket" in sys.argv[1:]
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

    @test("GET / sends end with matching context")
    def _():
        status, body = runtime.request("/", "inv-a", 1)
        check(status == 200, "status %r" % status)
        check(b"running natively on Vercel" in body, "body %r" % body)
        check(runtime.wait_for_end("inv-a", 1) == 1, "expected exactly one end")

    @test("internal headers are stripped and OIDC token exposed")
    def _():
        status, body = runtime.request(
            "/headers", "inv-a", 2, {"x-vercel-internal-oidc-token": "oidc-123"})
        check(status == 200, "status %r" % status)
        names = json.loads(body)
        leaked = [name for name in names if name.startswith("x-vercel-internal-")]
        check(not leaked, "leaked internal headers: %r" % leaked)
        check("x-vercel-oidc-token" in names, "missing x-vercel-oidc-token in %r" % names)
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

    @test("JSON route")
    def _():
        status, body = runtime.request("/json", "inv-a", 3)
        check(status == 200, "status %r" % status)
        payload = json.loads(body)
        check(payload.get("region") == "dev1", "payload %r" % payload)
        runtime.wait_for_end("inv-a", 3)

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

    @test("streaming response delivers all chunks")
    def _():
        started = time.monotonic()
        status, body = runtime.request("/stream", "inv-a", 6)
        check(status == 200, "status %r" % status)
        check(body == b"".join(b"chunk %d\n" % i for i in range(1, 6)), "body %r" % body)
        check(time.monotonic() - started >= 0.8, "stream finished too fast")
        runtime.wait_for_end("inv-a", 6)

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
        # responder, so the adapter must still end the invocation, exactly once.
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

    @test("every log belongs to a request that ended, and no unexpected messages")
    def _():
        with runtime.lock:
            orphans = [key for key in runtime.logs if key not in runtime.ends]
            other = list(runtime.other_messages)
        check(not orphans, "logs for requests that never ended: %r" % orphans)
        check(not other, "unexpected: %r" % other)

    @test("exits cleanly on SIGTERM")
    def _():
        code = runtime.stop()
        check(code == 0, "exit code %r" % code)

    failed = [name for name, error in results if error]
    print("\n%d passed, %d failed" % (len(results) - len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
