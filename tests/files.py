#!/usr/bin/env python3
"""Static-file behavior and safety checks, with optional Caddy comparisons."""
import email.parser
import gzip
import html
import http.client
import json
import os
from pathlib import Path
import sys
import tempfile

from compatibility import server


def get(conn, path, method='GET', headers=None):
    conn.request(method, path, headers={'Host': 'localhost', **(headers or {})})
    reply = conn.getresponse()
    body = reply.read()
    fields = {k.lower(): v for k, v in reply.getheaders()}
    return reply.status, fields, body


def run(vaddy, caddy=None):
    with tempfile.TemporaryDirectory(prefix='vaddy-files-') as directory:
        root = Path(directory)
        public = root / 'public'
        public.mkdir()
        (public / 'index.html').write_text('<h1>Hello</h1>\n')
        (public / 'hello.txt').write_bytes(b'0123456789abcdefghijklmnopqrstuvwxyz')
        (public / 'empty.txt').touch()
        (public / 'README').write_text('Plain text without a file extension\n')
        (public / 'large.txt').write_bytes(b'file payload\n' * 100000)
        (public / 'image.png').write_bytes(b'\x89PNG\r\n\x1a\n' + b'x' * 600)
        (public / 'app.js').write_text('console.log("hello");\n')
        original = os.urandom(4 * 1024 * 1024)
        (public / 'secret.txt').write_text('PRIVATE')
        (root / 'outside.txt').write_text('OUTSIDE ROOT')
        (public / 'sub').mkdir()
        (public / 'sub' / 'index.txt').write_text('Subdirectory index\n')
        (public / 'list').mkdir()
        escaped_name = 'quote&name.txt' if os.name == 'nt' else '<script>.txt'
        (public / 'list' / escaped_name).write_text('escaped')
        (public / 'list' / 'space name.txt').write_text('space')
        (public / 'list' / 'secret.txt').write_text('PRIVATE')
        if os.name != 'nt':
            os.mkfifo(public / 'pipe')
        comparisons = []
        for engine, binary in [('vaddy', vaddy)] + ([('caddy', caddy)] if caddy else []):
            results = []
            directives = f'root * "{public}"\nencode zstd gzip\nfile_server {{\n browse\n hide secret.txt\n}}'
            with server(binary, engine, directives) as (port, _):
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                status, fields, body = get(conn, '/hello.txt')
                assert status == 200 and body == (public / 'hello.txt').read_bytes()
                etag, modified = fields['etag'], fields['last-modified']
                cases = [('/', 'GET', {}), ('/hello.txt', 'HEAD', {}), ('/README', 'GET', {}),
                         ('/app.js', 'GET', {}), ('/image.png', 'GET', {}), ('/empty.txt', 'GET', {}),
                         ('/sub?x=1', 'GET', {}), ('/sub/', 'GET', {}), ('/hello.txt/', 'GET', {}),
                         ('/list', 'GET', {}), ('//sub', 'GET', {}), ('/missing', 'GET', {}),
                         ('/hello.txt', 'POST', {}), ('/secret.txt', 'GET', {}),
                         ('/../outside.txt', 'GET', {}), ('/%2e%2e/outside.txt', 'GET', {}),
                         ('/hello.txt', 'GET', {'Range': 'bytes=0-3'}),
                         ('/hello.txt', 'GET', {'Range': 'bytes=-5'}),
                         ('/hello.txt', 'GET', {'Range': 'bytes=30-'}),
                         ('/hello.txt', 'GET', {'Range': 'bytes=100-200'}),
                         ('/hello.txt', 'GET', {'If-None-Match': etag}),
                         ('/hello.txt', 'GET', {'If-None-Match': 'W/' + etag}),
                         ('/hello.txt', 'GET', {'If-Modified-Since': modified}),
                         ('/hello.txt', 'GET', {'If-Match': '"wrong"'}),
                         ('/hello.txt', 'GET', {'If-Unmodified-Since': 'Wed, 01 Jan 2020 00:00:00 GMT'}),
                         ('/hello.txt', 'GET', {'Range': 'bytes=0-3', 'If-Range': etag}),
                         ('/hello.txt', 'GET', {'Range': 'bytes=0-3', 'If-Range': '"wrong"'})]
                for path, method, headers in cases:
                    status, fields, body = get(conn, path, method, headers)
                    assert b'PRIVATE' not in body and b'OUTSIDE ROOT' not in body, (engine, path)
                    selected = {k: v for k, v in fields.items() if k in {'content-type', 'etag', 'last-modified', 'accept-ranges', 'content-range', 'location', 'allow'}}
                    # Error-page presentation is configurable in Caddy; compare status only.
                    results.append((path, method, status, selected if status < 400 else {}, body if status < 400 else b''))
                status, fields, body = get(conn, '/hello.txt', headers={'Range': 'bytes=0-3,10-13'})
                assert status == 206
                message = email.parser.BytesParser().parsebytes(b'Content-Type: ' + fields['content-type'].encode() + b'\r\nMIME-Version: 1.0\r\n\r\n' + body)
                assert [part.get_payload(decode=True) for part in message.get_payload()] == [b'0123', b'abcd']
                status, fields, body = get(conn, '/large.txt', headers={'Accept-Encoding': 'gzip'})
                assert gzip.decompress(body) == (public / 'large.txt').read_bytes()
                cached = get(conn, '/large.txt', headers={'Accept-Encoding': 'gzip', 'If-None-Match': fields['etag']})
                assert cached[0] == 304 and cached[1]['vary'] == 'Accept-Encoding'
                status, fields, body = get(conn, '/list/', headers={'Accept': 'application/json'})
                listing = json.loads(body)
                assert status == 200
                assert sorted(item['name'] for item in listing) == sorted([escaped_name, 'space name.txt'])
                assert all(item['is_dir'] is False for item in listing)
                status, fields, body = get(conn, '/list/')
                assert html.escape(escaped_name).encode() in body and escaped_name.encode() not in body and b'secret.txt' not in body
                if os.name != 'nt' and engine == 'vaddy':
                    assert get(conn, '/pipe')[0] == 404
                assert get(conn, '/hello.txt')[2] == (public / 'hello.txt').read_bytes(), 'keep-alive after file responses'
                (public / 'atomic.bin').write_bytes(original)
                conn.request('GET', '/atomic.bin', headers={'Host': 'localhost'})
                response = conn.getresponse()
                first = response.read(1024)
                if os.name != 'nt':
                    replacement = public / 'replacement.bin'
                    replacement.write_bytes(b'new file')
                    replacement.replace(public / 'atomic.bin')
                assert first + response.read() == original, 'file changed during an in-flight response'
                conn.close()
            # Route-scoped root, matcher and rewrite, plus proxy-free site configuration.
            directives = f'handle /mapped {{\n root * "{public}"\n rewrite * /hello.txt\n file_server\n}}\nfile_server /assets/* {{\n root "{public}"\n}}'
            with server(binary, engine, directives) as (port, _):
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                assert get(conn, '/mapped')[2] == (public / 'hello.txt').read_bytes()
                conn.close()
            comparisons.append(results)
            print(f'PASS {engine}: static files, indexes, MIME, HEAD, redirects, listing, ranges, validators, compression, hidden files and traversal')
        if caddy:
            mismatches = [(a, b) for a, b in zip(*comparisons) if a != b]
            assert not mismatches, mismatches
            print(f'Static file compatibility: {len(comparisons[0])} cases plus multipart and compressed cache checks')


if __name__ == '__main__':
    run(*(str(Path(arg).resolve()) for arg in sys.argv[1:]))
