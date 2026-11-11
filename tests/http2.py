#!/usr/bin/env python3
"""Independent hyper-h2 wire tests; also run against the supplied Caddy binary."""
import contextlib
import gzip
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

import h2.config
import h2.connection
import h2.events
import h2.settings

from integration import free_port

RANDOM = os.urandom(256 * 1024)


class Backend(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    release = threading.Event()
    entered = threading.Event()

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == '/held':
            self.entered.set()
            self.release.wait(5)
        if self.path == '/chunked':
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            self.wfile.write(b'3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n')
            return
        body = b'x' * (1024 * 1024) if self.path == '/large' else self.path.encode()
        if self.path == '/random':
            body = RANDOM
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Set-Cookie', 'a=1')
        self.send_header('Set-Cookie', 'b=2')
        self.end_headers()
        if self.command != 'HEAD':
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    do_HEAD = do_GET

    def do_POST(self):
        if self.headers.get('Transfer-Encoding') == 'chunked':
            body = bytearray()
            while True:
                length = int(self.rfile.readline().strip(), 16)
                if not length:
                    assert self.rfile.readline() == b'\r\n'
                    break
                body.extend(self.rfile.read(length))
                assert self.rfile.read(2) == b'\r\n'
        else:
            body = self.rfile.read(int(self.headers['Content-Length']))
        reply = hashlib.sha256(body).hexdigest().encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)


class Client:
    def __init__(self, port, cert, window=65535):
        ctx = ssl.create_default_context(cafile=str(cert))
        ctx.set_alpn_protocols(['h2', 'http/1.1'])
        self.sock = ctx.wrap_socket(socket.create_connection(('127.0.0.1', port), timeout=5), server_hostname='localhost')
        assert self.sock.selected_alpn_protocol() == 'h2'
        self.h2 = h2.connection.H2Connection(config=h2.config.H2Configuration(header_encoding='utf-8'))
        self.h2.initiate_connection()
        self.h2.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: window})
        self.bodies, self.headers, self.ended, self.reset = {}, {}, set(), set()
        self.flush()

    def flush(self):
        self.sock.sendall(self.h2.data_to_send())

    def request(self, path, method='GET', length=None, upload=False, headers=()):
        sid = self.h2.get_next_available_stream_id()
        fields = [(':method', method), (':scheme', 'https'), (':authority', 'localhost'), (':path', path)]
        fields.extend(headers)
        if length is not None:
            fields.append(('content-length', str(length)))
        self.h2.send_headers(sid, fields, end_stream=not upload)
        self.flush()
        return sid

    def receive(self, acknowledge=True):
        raw = self.sock.recv(65536)
        assert raw, 'HTTP/2 connection closed unexpectedly'
        events = self.h2.receive_data(raw)
        for event in events:
            if isinstance(event, h2.events.ResponseReceived):
                self.headers[event.stream_id] = event.headers
            elif isinstance(event, h2.events.DataReceived):
                self.bodies.setdefault(event.stream_id, bytearray()).extend(event.data)
                if acknowledge:
                    self.h2.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            elif isinstance(event, h2.events.StreamEnded):
                self.ended.add(event.stream_id)
            elif isinstance(event, h2.events.StreamReset):
                self.reset.add(event.stream_id)
            elif isinstance(event, h2.events.ConnectionTerminated):
                assert event.error_code == 0, event
        self.flush()
        return events

    def result(self, sid):
        while sid not in self.ended:
            assert sid not in self.reset, f'stream {sid} reset'
            self.receive()
        assert dict(self.headers[sid])[':status'] == '200', self.headers[sid]
        return bytes(self.bodies.get(sid, b''))

    def upload(self, payload, length):
        sid = self.request('/upload', 'POST', length, True)
        pos = 0
        while pos < len(payload):
            limit = min(self.h2.local_flow_control_window(sid), self.h2.max_outbound_frame_size, len(payload) - pos)
            if not limit:
                self.receive()
                continue
            self.h2.send_data(sid, payload[pos:pos + limit], end_stream=pos + limit == len(payload))
            pos += limit
            self.flush()
        assert self.result(sid).decode() == hashlib.sha256(payload).hexdigest()


@contextlib.contextmanager
def server(binary, engine, backend):
    with tempfile.TemporaryDirectory(prefix='vaddy-http2-') as directory:
        root = Path(directory)
        subprocess.run([os.environ.get('VADDY_OPENSSL', 'openssl'), 'req', '-new', '-x509', '-newkey', 'ec',
                        '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-days', '1', '-subj', '/CN=localhost',
                        '-addext', 'subjectAltName=DNS:localhost', '-keyout', str(root / 'key.pem'),
                        '-out', str(root / 'cert.pem')], check=True, capture_output=True)
        port, plain = free_port(), free_port()
        config = root / 'Caddyfile'
        config.write_text(f'''{{
 admin off
 http_port {plain}
 https_port {port}
}}
localhost {{
 encode zstd gzip
 header X-Generation old
 tls "{root / 'cert.pem'}" "{root / 'key.pem'}"
 log {{
  output file "{root / 'access.jsonl'}"
 }}
 redir /redirect /target 308
 reverse_proxy 127.0.0.1:{backend.server_port}
}}
''')
        args = [binary, 'run', '--config', str(config)]
        if engine == 'vaddy':
            args += ['--data', str(root / 'data'), '--bind', '127.0.0.1', '--workers', '2']
        with (root / 'diagnostics').open('w+') as log:
            process = subprocess.Popen(args, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while True:
                    assert process.poll() is None, 'server exited'
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.2):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(.03)
                yield port, root, process
            finally:
                Backend.release.set()
                process.terminate()
                try:
                    process.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                if sys.exc_info()[0]:
                    log.seek(0)
                    print(log.read(), file=sys.stderr)


def run(binary, engine):
    backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Backend)
    backend.daemon_threads = True
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    try:
        with server(binary, engine, backend) as (port, root, process):
            client = Client(port, root / 'cert.pem')
            try:
                slow = client.request('/held')
                fast = [client.request(f'/fast/{i}') for i in range(12)]
                for i, sid in enumerate(fast):
                    assert client.result(sid) == f'/fast/{i}'.encode()
                assert slow not in client.ended, 'slow stream blocked concurrent requests'
                Backend.release.set()
                assert client.result(slow) == b'/held'
                assert client.result(client.request('/large')) == b'x' * (1024 * 1024)
                compressed = client.request('/large', headers=[('accept-encoding', 'gzip')])
                assert gzip.decompress(client.result(compressed)) == b'x' * (1024 * 1024)
                assert dict(client.headers[compressed])['content-encoding'] == 'gzip'
                compressed = client.request('/random', headers=[('accept-encoding', 'gzip')])
                assert gzip.decompress(client.result(compressed)) == RANDOM
                assert client.result(client.request('/chunked')) == b'onetwo'
                assert client.result(client.request('/head', 'HEAD')) == b''
                sid = client.request('/cookies')
                assert client.result(sid) == b'/cookies'
                assert [v for k, v in client.headers[sid] if k == 'set-cookie'] == ['a=1', 'b=2']
                payload = os.urandom(512 * 1024)
                client.upload(payload, len(payload))
                client.upload(payload, None)
                cancelled = client.request('/large')
                client.h2.reset_stream(cancelled)
                client.flush()
                assert client.result(client.request('/after-reset')) == b'/after-reset'
                sid = client.request('/redirect', 'POST', upload=True)
                while sid not in client.ended:
                    client.receive()
                assert dict(client.headers[sid])[':status'] == '308'
                assert dict(client.headers[sid])['location'] == '/target'
                # Cancel uploads with unconsumed connection credit repeatedly.
                for _ in range(8):
                    sid = client.request('/upload', 'POST', 100000, True)
                    while client.h2.local_flow_control_window(sid) < 8192:
                        client.receive()
                    client.h2.send_data(sid, b'x' * 8192)
                    client.h2.reset_stream(sid)
                    client.flush()
                client.upload(payload, len(payload))
                if engine == 'vaddy':
                    Backend.release.clear()
                    Backend.entered.clear()
                    old = client.request('/held')
                    assert Backend.entered.wait(3)
                    config = root / 'Caddyfile'
                    config.write_text(config.read_text().replace('X-Generation old', 'X-Generation new'))
                    result = subprocess.run([binary, 'reload', '--config', str(config), '--data', str(root / 'data')], capture_output=True, timeout=15)
                    assert result.returncode == 0, result.stderr
                    new = client.request('/new-generation')
                    assert client.result(new) == b'/new-generation'
                    assert dict(client.headers[new])['x-generation'] == 'new'
                    Backend.release.set()
                    assert client.result(old) == b'/held'
                    assert dict(client.headers[old])['x-generation'] == 'old'
            finally:
                client.sock.close()
            # A blocked stream must not consume another stream's window.
            client = Client(port, root / 'cert.pem', 1024)
            try:
                blocked = client.request('/large')
                fast = client.request('/fast')
                while fast not in client.ended:
                    client.receive(acknowledge=False)
                assert bytes(client.bodies[fast]) == b'/fast'
                assert len(client.bodies.get(blocked, b'')) <= 1024
                client.h2.reset_stream(blocked)
                client.flush()
            finally:
                client.sock.close()
            # HTTP/1 ALPN and clients without ALPN continue to work.
            for protocols in ([], ['http/1.1']):
                ctx = ssl.create_default_context(cafile=str(root / 'cert.pem'))
                ctx.set_alpn_protocols(protocols)
                conn = http.client.HTTPSConnection('localhost', port, context=ctx, timeout=5)
                conn.request('GET', '/fallback')
                assert conn.getresponse().read() == b'/fallback'
                conn.close()
            deadline = time.monotonic() + 3
            while True:
                records = [json.loads(x) for x in (root / 'access.jsonl').read_text().splitlines()]
                uploads = [r for r in records if r['request']['uri'] == '/upload' and r['status'] == 200]
                if len(uploads) == 3:
                    break
                assert time.monotonic() < deadline, 'missing HTTP/2 access records'
                time.sleep(.02)
            assert all(r['request']['proto'] == 'HTTP/2.0' and r['bytes_read'] == len(payload) and r['size'] == 64 for r in uploads), uploads
            if engine == 'vaddy' and os.name != 'nt':
                # Inspect frames directly: hyper-h2 disallows response DATA after GOAWAY.
                client = Client(port, root / 'cert.pem')
                Backend.release.clear()
                Backend.entered.clear()
                sid = client.request('/held')
                assert Backend.entered.wait(3)
                process.terminate()
                wire, goaway, ended, body = bytearray(), False, False, bytearray()
                while not ended:
                    chunk = client.sock.recv(65536)
                    assert chunk, 'shutdown dropped active stream'
                    wire.extend(chunk)
                    while len(wire) >= 9:
                        size = int.from_bytes(wire[:3], 'big')
                        if len(wire) < size + 9:
                            break
                        kind, flags, stream = wire[3], wire[4], int.from_bytes(wire[5:9], 'big')
                        payload_bytes = bytes(wire[9:9 + size])
                        del wire[:9 + size]
                        if kind == 7:
                            goaway = True
                            Backend.release.set()
                        if kind == 0 and stream == sid:
                            body.extend(payload_bytes)
                            ended = bool(flags & 1)
                assert goaway and body == b'/held'
                client.sock.close()
                process.wait(timeout=5)
        print(f'PASS {engine}: HTTP/2 ALPN, multiplexing, large transfers, chunked conversion, HEAD, cookies, resets, early response, flow control, access logs, HTTP/1 fallback')
    finally:
        backend.shutdown()
        backend.server_close()


if __name__ == '__main__':
    for i, name in enumerate(sys.argv[1:] or ['./vaddy']):
        Backend.release.clear()
        run(str(Path(name).resolve()), 'vaddy' if i == 0 else 'caddy')
