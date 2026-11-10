#!/usr/bin/env python3
"""Real TCP/TLS smoke test; uses ephemeral loopback ports, never a public CA."""
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


class Backend(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/stream":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for part in (b"first", b"second", b"third"):
                self.wfile.write(f"{len(part):x}\r\n".encode() + part + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            return
        body = json.dumps({"path": self.path, "headers": dict(self.headers)}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Set-Cookie", "a=1")
        self.send_header("Set-Cookie", "b=2")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        data = self.rfile.read(int(self.headers["Content-Length"]))
        body = hashlib.sha256(data).hexdigest().encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run(binary):
    backend = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Backend)
    backend.daemon_threads = True
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    http_port, https_port = free_port(), free_port()
    while http_port == https_port:
        https_port = free_port()
    with tempfile.TemporaryDirectory(prefix="vaddy-integration-") as directory:
        root = Path(directory)
        config = (ROOT / "Caddyfile").read_text()
        config = config.replace("example.org {", f'localhost {{\n log {{\n output file "{root / "access.jsonl"}"\n }}\n        tls internal')
        config = config.replace("localhost:8001", f"127.0.0.1:{backend.server_port}")
        (root / "Caddyfile").write_text(config)
        with (root / "server.log").open("w+") as log:
            proc = subprocess.Popen([
                binary, "run", "--config", str(root / "Caddyfile"),
                "--data", str(root / "data"), "--bind", "127.0.0.1",
                "--http-port", str(http_port), "--https-port", str(https_port), "--workers", "3",
            ], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    assert proc.poll() is None, "vaddy exited at startup"
                    if (root / "data" / "current").exists():
                        break
                    time.sleep(0.1)
                else:
                    raise AssertionError("certificate issuance timed out")
                context = ssl.create_default_context(cafile=str(root / "data/pki/root.crt"))
                # Certificate publication and listener context replacement are independent.
                while True:
                    try:
                        conn = http.client.HTTPSConnection("localhost", https_port, context=context, timeout=3)
                        conn.request("GET", "/ready")
                        response = conn.getresponse()
                        assert response.status == 200
                        response.read()
                        break
                    except (OSError, http.client.HTTPException):
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(0.1)
                cases = {
                    "/": "/",
                    "/assets/a.js?v=2": "/static/assets/a.js?v=2",
                    "/app.js": "/static/app.js",
                    "/styles.css": "/static/styles.css",
                    "/manifest.webmanifest": "/static/manifest.webmanifest",
                    "/favicon.ico?old=1": "/static/assets/favicon.ico?old=1",
                    "/favicon.svg": "/static/assets/favicon.svg",
                    "/api/test?q=1": "/api/test?q=1",
                }
                for path, expected in cases.items():
                    conn.request("GET", path, headers={"X-Forwarded-For": "spoof", "X-Forwarded-Proto": "http"})
                    response = conn.getresponse()
                    assert response.status == 200
                    assert response.getheader("Cross-Origin-Embedder-Policy") is None
                    assert response.getheader("Cross-Origin-Opener-Policy") is None
                    assert len([1 for key, _ in response.getheaders() if key.lower() == "set-cookie"]) == 2
                    body = json.loads(response.read())
                    assert body["path"] == expected, body
                    assert body["headers"]["X-Forwarded-For"] == "127.0.0.1"
                    assert body["headers"]["X-Forwarded-Proto"] == "https"
                payload = os.urandom(2 * 1024 * 1024)
                conn.request("POST", "/upload", body=payload)
                response = conn.getresponse()
                assert response.read().decode() == hashlib.sha256(payload).hexdigest()
                conn.request("GET", "/stream")
                assert conn.getresponse().read() == b"firstsecondthird"
                conn.close()
                plain = http.client.HTTPConnection("localhost", http_port, timeout=3)
                plain.request("GET", "/assets/a.js?x=1")
                response = plain.getresponse()
                assert response.status == 308
                assert response.getheader("Location") == f"https://localhost:{https_port}/assets/a.js?x=1"
                response.read()
                plain.close()
                with socket.create_connection(("127.0.0.1", http_port), timeout=3) as raw:
                    raw.sendall(b"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n")
                    assert raw.recv(1024).startswith(b"HTTP/1.1 400")
                def parallel_request(i):
                    client = http.client.HTTPConnection('localhost', http_port, timeout=3)
                    client.request('GET', f'/parallel/{i}')
                    reply = client.getresponse()
                    assert reply.status == 308
                    reply.read()
                    client.close()
                import concurrent.futures
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    list(pool.map(parallel_request, range(40)))
                records = [json.loads(line) for line in (root / 'access.jsonl').read_text().splitlines()]
                parallel = [r for r in records if r['request']['uri'].startswith('/parallel/')]
                assert len(parallel) == 40
                assert all(r['status'] == 308 and r['size'] == 0 for r in parallel)
                print("PASS: TCP, verified TLS, supplied routes, redirects, headers, keep-alive, streaming, uploads, malformed framing")
            finally:
                proc.terminate()
                try:
                    proc.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                log.seek(0)
                print(log.read(), end="", file=sys.stderr)
    backend.shutdown()
    backend.server_close()


if __name__ == "__main__":
    run(str(Path(sys.argv[1] if len(sys.argv) > 1 else "./vaddy").resolve()))
