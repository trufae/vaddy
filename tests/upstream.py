#!/usr/bin/env python3
"""Verified HTTPS backends, failed verification, reuse, and streaming."""
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
import time

from integration import Backend, free_port


class TLSBackend(Backend):
    def do_GET(self):
        if self.path == '/large':
            body = b'x' * (2 * 1024 * 1024)
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            super().do_GET()


def run(binary):
    with tempfile.TemporaryDirectory(prefix='vaddy-upstream-') as directory:
        root = Path(directory)
        exe = os.environ.get('VADDY_OPENSSL', 'openssl')
        subprocess.run([exe, 'req', '-new', '-x509', '-newkey', 'ec', '-pkeyopt',
                        'ec_paramgen_curve:P-256', '-nodes', '-days', '1', '-subj', '/CN=localhost',
                        '-addext', 'subjectAltName=DNS:localhost', '-keyout', str(root / 'key.pem'),
                        '-out', str(root / 'cert.pem')], check=True, capture_output=True)
        backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), TLSBackend)
        backend.daemon_threads = True
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(root / 'cert.pem', root / 'key.pem')
        names = []
        ctx.set_servername_callback(lambda sock, name, context: names.append(name))
        backend.socket = ctx.wrap_socket(backend.socket, server_side=True)
        threading.Thread(target=backend.serve_forever, daemon=True).start()
        try:
            for mode in ('trusted', 'untrusted', 'wrong-name', 'ip-mismatch'):
                port = free_port()
                upstream = f'https://127.0.0.1:{backend.server_port}'
                transport = ''
                if mode != 'untrusted':
                    name = '' if mode == 'ip-mismatch' else 'tls_server_name ' + ('wrong.example' if mode == 'wrong-name' else 'localhost')
                    transport = f' {{\n transport http {{\n {name}\n tls_trust_pool file "{root / "cert.pem"}"\n }}\n }}'
                config = root / 'Caddyfile'
                config.write_text(f'http://localhost {{\n reverse_proxy {upstream}{transport}\n}}\n')
                with (root / 'log').open('w+') as log:
                    proc = subprocess.Popen([binary, '--config', str(config), '--data', str(root / 'data'),
                                             '--bind', '127.0.0.1', '--http-port', str(port), '--workers', '2'],
                                            stdout=log, stderr=log)
                    try:
                        deadline = time.monotonic() + 10
                        while True:
                            assert proc.poll() is None, 'vaddy exited'
                            try:
                                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
                                conn.request('GET', '/hello?x=1', headers={'Host': 'localhost'})
                                response = conn.getresponse()
                                break
                            except ConnectionRefusedError:
                                if time.monotonic() >= deadline:
                                    raise
                                time.sleep(.05)
                        if mode != 'trusted':
                            assert response.status == 502, (mode, response.status)
                            response.read()
                        else:
                            assert response.status == 200
                            body = json.loads(response.read())
                            assert body['path'] == '/hello?x=1'
                            assert body['headers']['Host'] == f'127.0.0.1:{backend.server_port}'
                            assert body['headers']['X-Forwarded-Host'] == 'localhost'
                            assert names[-1] == 'localhost'
                            for _ in range(3):
                                conn.request('GET', '/stream', headers={'Host': 'localhost'})
                                assert conn.getresponse().read() == b'firstsecondthird'
                            payload = os.urandom(2 * 1024 * 1024)
                            conn.request('POST', '/upload', body=payload, headers={'Host': 'localhost'})
                            assert conn.getresponse().read().decode() == hashlib.sha256(payload).hexdigest()
                            conn.request('GET', '/large', headers={'Host': 'localhost'})
                            assert conn.getresponse().read() == b'x' * (2 * 1024 * 1024)
                        conn.close()
                    finally:
                        proc.terminate()
                        proc.wait(timeout=12)
                        if sys.exc_info()[0]:
                            log.seek(0)
                            print(log.read(), file=sys.stderr)
        finally:
            backend.shutdown()
            backend.server_close()
    print('PASS: HTTPS upstream verification, SNI, Host, keep-alive, chunked streaming, large uploads/downloads, rejection of untrusted/wrong-name/IP certificates')


if __name__ == '__main__':
    run(str(Path(sys.argv[1] if len(sys.argv) > 1 else './vaddy').resolve()))
