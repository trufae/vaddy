#!/usr/bin/env python3
"""Compare decoded representations and cache headers, not codec-specific bytes."""
import ctypes
import ctypes.util
import gzip
import http.client
import http.server
import os
from pathlib import Path
import sys
import threading
import zlib

from compatibility import server


BODY = (b'Hello from a compressed Vaddy response!\n' * 30000)
RANDOM = os.urandom(1024 * 1024)
RELEASE = threading.Event()


class Backend(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        status = 206 if self.path == '/range' else 304 if self.path == '/cached' else 200
        body = BODY[:int(self.path[6:])] if self.path.startswith('/size/') else BODY
        if self.path == '/random':
            body = RANDOM
        if self.path == '/sse':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            self.wfile.write(b'9\r\ndata: 1\n\n\r\n')
            self.wfile.flush()
            RELEASE.wait(5)
            self.wfile.write(b'9\r\ndata: 2\n\n\r\n0\r\n\r\n')
            return
        if self.path == '/conditional':
            assert self.headers['If-None-Match'] == '"original"', self.headers
        self.send_response(status)
        self.send_header('Content-Type', 'image/png' if self.path == '/image' else 'text/plain')
        self.send_header('Etag', '"original"')
        self.send_header('Accept-Ranges', 'bytes')
        if self.path == '/no-transform':
            self.send_header('Cache-Control', 'public, no-transform')
        if self.path == '/already':
            self.send_header('Content-Encoding', 'gzip')
            body = gzip.compress(body)
        if self.path == '/chunked':
            self.send_header('Transfer-Encoding', 'chunked')
        elif status != 304:
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command == 'HEAD' or status == 304:
            return
        if self.path == '/chunked':
            for i in range(0, len(body), 4096):
                part = body[i:i + 4096]
                self.wfile.write(f'{len(part):x}\r\n'.encode() + part + b'\r\n')
            self.wfile.write(b'0\r\n\r\n')
        else:
            self.wfile.write(body)

    do_HEAD = do_GET


def unzstd(data, capacity=len(BODY)):
    library = ctypes.util.find_library('zstd') or 'libzstd.dll'
    lib = ctypes.CDLL(library)
    lib.ZSTD_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
    lib.ZSTD_decompress.restype = ctypes.c_size_t
    output = ctypes.create_string_buffer(capacity)
    size = lib.ZSTD_decompress(output, capacity, data, len(data))
    assert size <= capacity, f'zstd decompression failed: {size}'
    return output.raw[:size]


def run(vaddy, caddy=None):
    backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Backend)
    backend.daemon_threads = True
    threading.Thread(target=backend.serve_forever, daemon=True).start()
    cases = [('/large', 'gzip'), ('/large', 'zstd'), ('/large', 'gzip;q=0.5, zstd;q=0.9'),
             ('/large', 'zstd, gzip'), ('/large', 'gzip;q=0'), ('/large', 'identity'),
             ('/large', '*'), ('/size/511', 'gzip'), ('/size/512', 'gzip'), ('/size/513', 'gzip'),
             ('/image', 'gzip'), ('/no-transform', 'gzip'), ('/already', 'gzip'),
             ('/range', 'gzip'), ('/cached', 'gzip'), ('/conditional', 'gzip'), ('/chunked', 'gzip'),
             ('/random', 'gzip'), ('/random', 'zstd')]
    outputs = []
    try:
        for engine, binary in [('vaddy', vaddy)] + ([('caddy', caddy)] if caddy else []):
            engine_results = []
            directives = f'encode zstd gzip\nreverse_proxy 127.0.0.1:{backend.server_port}'
            with server(binary, engine, directives) as (port, _):
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=8)
                for path, accept in cases:
                    conn.request('GET', path, headers={'Host': 'localhost', 'Accept-Encoding': accept, 'If-None-Match': '"original-gzip"'})
                    response = conn.getresponse()
                    try:
                        raw = response.read()
                    except Exception as error:
                        raise AssertionError((engine, path, accept)) from error
                    encoding = response.getheader('Content-Encoding')
                    decoded = gzip.decompress(raw) if encoding == 'gzip' else unzstd(raw) if encoding == 'zstd' else raw
                    expected = b'' if path == '/cached' else BODY[:int(path[6:])] if path.startswith('/size/') else BODY
                    if path == '/random':
                        expected = RANDOM
                    assert decoded == expected, (engine, path, encoding, len(decoded), len(expected))
                    engine_results.append((path, accept, response.status, encoding,
                                           response.getheader('Vary'), response.getheader('Etag'), response.getheader('Accept-Ranges')))
                conn.request('HEAD', '/large', headers={'Host': 'localhost', 'Accept-Encoding': 'gzip'})
                response = conn.getresponse()
                assert response.read() == b'' and response.getheader('Content-Encoding') == 'gzip'
                conn.close()
                # Wait for the first decompressed SSE event before allowing the second.
                RELEASE.clear()
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
                conn.request('GET', '/sse', headers={'Host': 'localhost', 'Accept-Encoding': 'gzip'})
                response = conn.getresponse()
                assert response.getheader('Content-Encoding') == 'gzip'
                decoder = zlib.decompressobj(31)
                first = bytearray()
                while b'data: 1\n\n' not in first:
                    first.extend(decoder.decompress(response.read1(1024)))
                RELEASE.set()
                assert bytes(first) + decoder.decompress(response.read()) == b'data: 1\n\ndata: 2\n\n'
                conn.close()
            outputs.append(engine_results)
            options = f'@compressed path /image /size/*\nencode @compressed {{\n gzip 6\n minimum_length 1024\n match status 200\n}}\nreverse_proxy 127.0.0.1:{backend.server_port}'
            with server(binary, engine, options) as (port, _):
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                for path, encoding in [('/image', 'gzip'), ('/large', None), ('/size/513', None)]:
                    conn.request('GET', path, headers={'Host': 'localhost', 'Accept-Encoding': 'gzip'})
                    response = conn.getresponse()
                    assert response.getheader('Content-Encoding') == encoding, (engine, path)
                    raw = response.read()
                    body = gzip.decompress(raw) if encoding else raw
                    assert body == (BODY[:513] if path == '/size/513' else BODY)
                conn.close()
            print(f'PASS {engine}: gzip/zstd decoding, negotiation, thresholds, exclusions, cache headers, HEAD, chunks, incremental SSE')
        if caddy:
            for a, b in zip(*outputs):
                assert a == b, (a, b)
            print(f'Compression compatibility: {len(cases)} cases')
    finally:
        RELEASE.set()
        backend.shutdown()
        backend.server_close()


if __name__ == '__main__':
    run(*(str(Path(name).resolve()) for name in sys.argv[1:]))
