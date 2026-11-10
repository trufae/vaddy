#!/usr/bin/env python3
"""Transactional reloads preserve in-flight streams and update every worker."""
import concurrent.futures
import http.client
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from integration import Backend, free_port


class ReloadBackend(Backend):
    def do_GET(self):
        self.server.used.set()
        if self.path == '/hold':
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            self.wfile.write(b'5\r\nfirst\r\n')
            self.wfile.flush()
            self.server.release.wait(20)
            self.wfile.write(b'4\r\nlast\r\n0\r\n\r\n')
            self.wfile.flush()
        elif self.path == '/ws':
            self.send_response(101)
            self.send_header('Connection', 'Upgrade')
            self.send_header('Upgrade', 'websocket')
            self.end_headers()
            self.wfile.flush()
            while True:
                byte = self.rfile.read(1)
                if not byte:
                    break
                self.wfile.write(byte)
                self.wfile.flush()
            self.close_connection = True
        else:
            super().do_GET()


def run(binary):
    backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), ReloadBackend)
    backend.release = threading.Event()
    backend.used = threading.Event()
    backend.daemon_threads = True
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    second = http.server.ThreadingHTTPServer(('127.0.0.1', 0), ReloadBackend)
    second.release = threading.Event()
    second.used = threading.Event()
    second.daemon_threads = True
    threading.Thread(target=second.serve_forever, daemon=True).start()
    try:
        for workers in (1, 3):
            backend.release.clear()
            with tempfile.TemporaryDirectory(prefix='vaddy-reload-') as directory:
                root = Path(directory)
                config = root / 'Caddyfile'
                port = free_port()

                def contents(generation, *, output=None, listen=None, proxy=None):
                    return (f'{{\n http_port {listen or port}\n}}\nhttp://localhost {{\n'
                            f' header X-Generation {generation}\n'
                            f' log {{\n output file "{output or root / "access.jsonl"}"\n }}\n'
                            f' redir /old /new-{generation} 308\n'
                            f' reverse_proxy {proxy or f"127.0.0.1:{backend.server_port}"} {{\n'
                            f' header_up X-Generation {generation}\n }}\n}}\n')

                def reload(text, success=True):
                    config.write_text(text)
                    result = subprocess.run([binary, 'reload', '--config', str(config), '--data', str(root / 'data')],
                                            capture_output=True, text=True, timeout=35)
                    assert (result.returncode == 0) == success, (result.stdout, result.stderr)

                def request(path='/check', conn=None):
                    own = conn is None
                    conn = conn or http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                    conn.request('GET', path, headers={'Host': 'localhost'})
                    response = conn.getresponse()
                    result = response.status, response.getheader('X-Generation'), response.getheader('Location'), response.read()
                    if own:
                        conn.close()
                    return result

                config.write_text(contents('old'))
                with (root / 'server.log').open('w+') as log:
                    proc = subprocess.Popen([binary, '--config', str(config), '--data', str(root / 'data'),
                                             '--bind', '127.0.0.1', '--workers', str(workers)], stdout=log, stderr=log)
                    hold = persistent = ws = None
                    try:
                        deadline = time.monotonic() + 10
                        while True:
                            assert proc.poll() is None
                            try:
                                assert request()[1] == 'old'
                                break
                            except ConnectionRefusedError:
                                if time.monotonic() > deadline:
                                    raise
                                time.sleep(.05)
                        persistent = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                        assert request(conn=persistent)[1] == 'old'
                        hold = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                        hold.request('GET', '/hold', headers={'Host': 'localhost'})
                        stream = hold.getresponse()
                        assert stream.getheader('X-Generation') == 'old'
                        assert stream.read(5) == b'first'
                        ws = socket.create_connection(('127.0.0.1', port), timeout=5)
                        ws.sendall(b'GET /ws HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n')
                        handshake = b''
                        while b'\r\n\r\n' not in handshake:
                            handshake += ws.recv(4096)
                        assert handshake.startswith(b'HTTP/1.1 101')
                        second.used.clear()
                        reload(contents('new', proxy=f'127.0.0.1:{second.server_port}'))
                        assert request(conn=persistent)[1] == 'new'
                        assert second.used.is_set()
                        ws.sendall(b'after-reload')
                        echoed = b''
                        while len(echoed) < 12:
                            echoed += ws.recv(12 - len(echoed))
                        assert echoed == b'after-reload'
                        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                            replies = list(pool.map(lambda i: request(f'/check/{i}'), range(30)))
                        assert all(r[1] == 'new' and json.loads(r[3])['headers']['X-Generation'] == 'new' for r in replies)
                        assert request('/old')[:3] == (308, 'new', '/new-new')
                        # Failed parsing, resource setup and listener changes leave all workers on the current config.
                        reload('invalid', False)
                        reload(contents('bad', output=root / 'missing/no.log'), False)
                        reload(contents('bad', listen=free_port()), False)
                        bad_tls = contents('bad').replace(f'reverse_proxy 127.0.0.1:{backend.server_port} {{',
                            f'reverse_proxy https://127.0.0.1:{backend.server_port} {{\n transport http {{\n tls_trust_pool file "{root / "missing-ca.pem"}"\n }}')
                        reload(bad_tls, False)
                        assert request(conn=persistent)[1] == 'new'
                        if os.name != 'nt':
                            config.write_text(contents('signal'))
                            proc.send_signal(signal.SIGHUP)
                            deadline = time.monotonic() + 5
                            while request()[1] != 'signal':
                                assert time.monotonic() < deadline
                                time.sleep(.05)
                        backend.release.set()
                        assert stream.read() == b'last'
                        hold.close()
                        ws.close()
                        ws = None
                        for i in range(3):
                            reload(contents(f'round-{i}'))
                            assert request(conn=persistent)[1] == f'round-{i}'
                        persistent.close()
                        records = [json.loads(line) for line in (root / 'access.jsonl').read_text().splitlines()]
                        assert len([r for r in records if r['request']['uri'] == '/hold']) == 1
                        assert all(r['size'] == 9 for r in records if r['request']['uri'] == '/hold')
                    finally:
                        backend.release.set()
                        for conn in (hold, persistent, ws):
                            if conn:
                                conn.close()
                        proc.terminate()
                        try:
                            proc.wait(timeout=12)
                        except subprocess.TimeoutExpired:
                            proc.kill()
                            proc.wait()
                            raise
                        if sys.exc_info()[0] or proc.returncode:
                            log.seek(0)
                            print(log.read(), file=sys.stderr)
                        if os.name != 'nt':
                            assert proc.returncode == 0
    finally:
        backend.shutdown()
        backend.server_close()
        second.shutdown()
        second.server_close()
    print('PASS: reload CLI, SIGHUP, keep-alive, streams, WebSockets, all workers, header/redirect/log updates, failed-config rollback and repeated generations')


if __name__ == '__main__':
    run(str(Path(sys.argv[1] if len(sys.argv) > 1 else './vaddy').resolve()))
