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
        config.write_text(f"{{\n admin off\n http_port {port}\n https_port {tls_port}\n}}\nhttp://localhost {{\n{directives}\n}}\n".replace("$LOG", str(root / "access.jsonl")))
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
        ('header >X-Value "(up)(stream)" "$2-$1"', ""),
        ('header >X-Value "(?P<part>up)stream" "${part}-$0-$$"', ""),
        ('header >X-Value "(up)" "$1suffix-${1}suffix"', ""),
        ('header >X-Value "" "-"', ""),
        ('header >X-Value "x*" "-"', ""),
        ('header >X-Value "[a-z]+" "replaced"', ""),
        ('header >X-Value "{header.X-Pattern}" "replaced"', ""),
        ("", 'header_down X-Value "(up)(stream)" "$2-$1"'),
        ('request_header X-Value "(ab)(cd)" "$2-$1"', ""),
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
                    outputs.append(request(conn, "GET", "/test", headers={"X-Value": "abcd", "X-Pattern": "["}))
                    conn.close()
            assert outputs[0] == outputs[1], (directives, proxy, outputs)
        print(f"header compatibility: {len(cases)} cases")
    finally:
        backend.shutdown()
        backend.server_close()


class LogBackend(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.headers.get("Transfer-Encoding") == "chunked":
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if not size:
                    self.rfile.readline()
                    break
                self.rfile.read(size + 2)
        else:
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.do_GET()

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Set-Cookie", "secret-cookie")
        if self.path == "/chunked":
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", "9")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b"5\r\nfirst\r\n4\r\nlast\r\n0\r\n\r\n" if self.path == "/chunked" else b"firstlast")


def logging(vaddy, caddy):
    backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), LogBackend)
    backend.daemon_threads = True
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    proxy = f"reverse_proxy 127.0.0.1:{backend.server_port}"
    cases = [(proxy, "GET", "/", None), (proxy, "HEAD", "/", None),
             (proxy, "GET", "/chunked", None), (proxy, "POST", "/", "abcdef"),
             (proxy, "POST", "/", [b"abc", b"def"]),
             ("redir * /new 308", "GET", "/", None),
             ("redir * /new html", "HEAD", "/", None)]
    try:
        for directive, method, target, body in cases:
            outputs = []
            for engine, binary in [("vaddy", vaddy), ("caddy", caddy)]:
                with server(binary, engine, 'log compat {\n output file "$LOG"\n format json\n}\n' + directive) as (port, root):
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                    request(conn, method, target, body=body, headers={"Authorization": "secret-auth", "Cookie": "secret-cookie"})
                    conn.close()
                    deadline = time.monotonic() + 3
                    while True:
                        text = (root / "access.jsonl").read_text()
                        if text.strip():
                            break
                        assert time.monotonic() < deadline, "no access log"
                        time.sleep(.01)
                    assert "secret-auth" not in text and "secret-cookie" not in text
                    record = json.loads(text)
                    assert 1e9 < record.pop("ts") < 1e10
                    assert 0 <= record.pop("duration") < 5
                    assert int(record["request"].pop("remote_port")) > 0
                    for name in ("Server", "Date", "Via"):
                        record["resp_headers"].pop(name, None)
                    outputs.append(record)
            assert outputs[0] == outputs[1], (directive, method, target, outputs)
        print(f"access-log compatibility: {len(cases)} cases")
    finally:
        backend.shutdown()
        backend.server_close()


def log_customization(vaddy, caddy):
    cases = [
        ('format json', 'log_skip /skip'),
        ('format json\nlevel WARN', 'log_level /warn WARN'),
        ('format json', 'log_append tag constant\nlog_append uri {uri}\nlog_append <early {query.token}\nlog_append response_status {http.response.status}'),
        ('format filter {\n wrap json\n fields {\n request>headers>Authorization delete\n request>remote_ip hash\n status rename code\n }\n}', ''),
        ('format filter {\n wrap json\n fields {\n request>uri query {\n replace token HIDDEN\n delete remove\n }\n }\n}', ''),
        ('format filter {\n wrap json\n fields {\n request>headers>X-Value regexp "(secret)" "hidden-$1"\n }\n}', ''),
        ('format append {\n wrap json\n fields {\n deployment dev\n number 12\n }\n}', ''),
    ]
    for encoder, directives in cases:
        outputs = []
        for engine, binary in [("vaddy", vaddy), ("caddy", caddy)]:
            config = 'log compat {\n output file "$LOG"\n' + encoder + '\n}\n' + directives + '\nredir * /new'
            with server(binary, engine, config) as (port, root):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                for path in ["/ok?token=secret&remove=yes&token=second", "/skip", "/warn"]:
                    request(conn, "GET", path, headers={"Authorization": "secret-auth", "X-Value": "secret"})
                conn.close()
                # Access logs are emitted at handler completion; wait for the final request.
                deadline = time.monotonic() + 3
                while True:
                    lines = (root / "access.jsonl").read_text().splitlines()
                    records = [json.loads(line) for line in lines]
                    if any(r["request"]["uri"] == "/warn" for r in records):
                        break
                    assert time.monotonic() < deadline, records
                    time.sleep(.01)
                for record in records:
                    record.pop("ts")
                    record.pop("duration")
                    record["request"].pop("remote_port")
                    for name in ("Server", "Date", "Via"):
                        record["resp_headers"].pop(name, None)
                outputs.append(records)
        assert outputs[0] == outputs[1], (encoder, directives, outputs)
    # Both logger instances receive ordinary traffic; log_name selects only one.
    outputs = []
    for engine, binary in [("vaddy", vaddy), ("caddy", caddy)]:
        config = 'log first {\n output file "$LOG"\n}\nlog second {\n output file "$LOG"\n}\nlog_name /selected second\nredir * /new'
        with server(binary, engine, config) as (port, root):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
            request(conn, "GET", "/both")
            request(conn, "GET", "/selected")
            conn.close()
            deadline = time.monotonic() + 3
            while True:
                records = [json.loads(line) for line in (root / "access.jsonl").read_text().splitlines()]
                if len(records) >= 3:
                    break
                assert time.monotonic() < deadline, records
                time.sleep(.01)
            outputs.append(sorted((r["logger"], r["request"]["uri"]) for r in records))
    assert outputs[0] == outputs[1], outputs
    print(f"log customization compatibility: {len(cases) + 1} cases")


if __name__ == "__main__":
    vaddy, caddy = map(lambda p: str(Path(p).resolve()), sys.argv[1:3])
    print("Reference:", subprocess.check_output([caddy, "version"], text=True).strip())
    redirects(vaddy, caddy)
    headers(vaddy, caddy)
    logging(vaddy, caddy)
    log_customization(vaddy, caddy)
