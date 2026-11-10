#!/usr/bin/env python3
"""Behavioral comparisons with an explicitly supplied Caddy binary."""
import contextlib
import http.client
import http.server
import threading
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

from integration import free_port


@contextlib.contextmanager
def server(binary, engine, directives):
    with tempfile.TemporaryDirectory(prefix=f"{engine}-compat-") as directory:
        root = Path(directory)
        port, tls_port = free_port(), free_port()
        config = root / "Caddyfile"
        config.write_text(f"{{\n admin off\n http_port {port}\n https_port {tls_port}\n}}\nhttp://localhost {{\n{directives}\n}}\n")
        args = [binary, "run", "--config", str(config), "--adapter", "caddyfile"]
        if engine == "vaddy":
            args += ["--bind", "127.0.0.1", "--data", str(root / "data")]
        with (root / "diagnostics").open("w+") as log:
            process = subprocess.Popen(args, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while True:
                    if process.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read())
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.2):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise AssertionError("listener did not start")
                        time.sleep(.02)
                yield port, root
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def request(conn, method, target, body=None, headers=None):
    conn.request(method, target, body=body, headers={"Host": "localhost", **(headers or {})})
    response = conn.getresponse()
    result = (response.status, sorted((k.lower(), v) for k, v in response.getheaders()
              if k.lower() not in {"server", "date", "via"}), response.read())
    return result


def redirects(vaddy, caddy):
    cases = [
        ("redir * /new", "GET", "/old"),
        ("redir /new 308", "GET", "/new"),
        ("redir * /new permanent", "HEAD", "/old"),
        ("redir * /new temporary", "POST", "/old"),
        ("redir * /new 300", "GET", "/old"),
        ("redir * /new 304", "GET", "/old"),
        ("redir * /new 305", "GET", "/old"),
        ("redir * /new 399", "GET", "/old"),
        ("redir * /new 401", "GET", "/old"),
        ('redir * "https://new.example/a?x=1&y=2" html', "GET", "/old"),
        ("redir * /new html", "HEAD", "/old"),
        ("redir * /new {query.code}", "GET", "/old?code=307"),
        ("redir * /new {header.X-Code}", "GET", "/old"),
        ("redir * https://new.example{path}?{query}", "GET", "/old?q=1"),
        ("redir * /{unknown}", "GET", "/old"),
    ]
    for directive, method, target in cases:
        outputs = []
        for engine, binary in [("vaddy", vaddy), ("caddy", caddy)]:
            with server(binary, engine, directive) as (port, _):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                outputs.append(request(conn, method, target, body="abc" if method == "POST" else None,
                                       headers={"X-Code": "308"}))
                first_socket = conn.sock
                second = request(conn, method, target, headers={"X-Code": "308"})
                assert conn.sock is first_socket, (engine, directive, "connection was not reused")
                assert second == outputs[-1], (engine, directive, second, outputs[-1])
                conn.close()
        assert outputs[0] == outputs[1], (directive, outputs)
    print(f"redirect compatibility: {len(cases)} cases, including connection reuse")


class HeaderBackend(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        body = json.dumps({k.lower(): self.headers.get_all(k) for k in self.headers
                           if k.lower().startswith("x-") or k.lower() == "host"}, sort_keys=True).encode()
        self.send_response(201)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "text/plain")
        self.send_header("X-Value", "upstream")
        self.send_header("X-Remove", "gone")
        self.send_header("Set-Cookie", "a=1")
        self.send_header("Set-Cookie", "b=2")
        self.end_headers()
        self.wfile.write(body)


def headers(vaddy, caddy):
    backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), HeaderBackend)
    backend.daemon_threads = True
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    cases = [
        ("header X-Value immediate", ""),
        ("header >X-Value deferred", ""),
        ("header X-Value site", "header_down X-Value proxy"),
        ("header >X-Value site", "header_down X-Value proxy"),
        ("header >X-Value first\nheader >X-Value second", ""),
        ("header ?X-Value default\nheader ?X-Missing default", ""),
        ("header {\n +X-Value extra\n X-Value set\n -X-Remove\n}", ""),
        ("header {\n -X-*\n +X-New added\n}", ""),
        ("header {\n -X-Value\n X-Value set\n}", ""),
        ("header {\n X-Value value\n defer\n}", ""),
        ("header {\n ?X-One one\n ?X-Two two\n}", ""),
        ("header {\n >X-Value conditional\n match {\n status 2xx\n header Content-Type text/*\n }\n}", ""),
        ("header {\n >X-Value conditional\n match {\n status 404\n }\n}", ""),
        ("@test path /test\nheader @test >X-Value match", ""),
        ("header /other >X-Value no", ""),
        ("request_header X-Forwarded-For spoofed", ""),
        ("request_header Host app.internal", ""),
        ("request_header +Host app.internal", ""),
        ("request_header -Host", ""),
        ("", "header_up +Host app.internal"),
        ("", "header_up -Host"),
        ("request_header X-Value before", "header_up +X-Value after"),
    ]
    try:
        for directives, proxy in cases:
            config = directives + f"\nreverse_proxy 127.0.0.1:{backend.server_port} {{\n{proxy}\n}}"
            outputs = []
            for engine, binary in [("vaddy", vaddy), ("caddy", caddy)]:
                with server(binary, engine, config) as (port, _):
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                    outputs.append(request(conn, "GET", "/test"))
                    conn.close()
            assert outputs[0] == outputs[1], (directives, proxy, outputs)
        print(f"header compatibility: {len(cases)} cases")
    finally:
        backend.shutdown()
        backend.server_close()


if __name__ == "__main__":
    vaddy, caddy = map(lambda p: str(Path(p).resolve()), sys.argv[1:3])
    print("Reference:", subprocess.check_output([caddy, "version"], text=True).strip())
    redirects(vaddy, caddy)
    headers(vaddy, caddy)
