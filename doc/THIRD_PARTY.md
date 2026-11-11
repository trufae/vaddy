# Third-party notices

The extension-to-media-type table in `src/mime_data.v` is extracted from V's
`vlib/net/http/mime/db.v`, revision `b7b4dd46eeb3d39cf8d3e8ef757093d872cbc230`.
It preserves every extension mapping, including V's additions. Regenerate with
`python3 tools/generate_mime.py .tools/v/vlib/net/http/mime/db.v`; the generated
file records the source hash. V's copyright and MIT license are included in
[licenses/V-MIT.txt](licenses/V-MIT.txt).
V's table is generated from [jshttp/mime-db](https://github.com/jshttp/mime-db).
Its MIT notice is included in [licenses/mime-db-MIT.txt](licenses/mime-db-MIT.txt).

The HTML redirect template in `src/redirect.v` (`html_redirect`) is adapted from
Caddy's `caddyconfig/httpcaddyfile/builtins.go`, revision
`8a6ab2b7bb3c6b83ed8d8031d6457375629858d8`. The surrounding implementation has been
rewritten in V.

Copyright 2015 Matthew Holt and The Caddy Authors.

That template is licensed under the Apache License, Version 2.0. A copy is
included in [licenses/Caddy-Apache-2.0.txt](licenses/Caddy-Apache-2.0.txt).

Vaddy also links to separately installed OpenSSL, RE2, zlib, nghttp2, Zstandard and the platform C++
runtime. Their packages carry their respective licenses and notices. RE2
matching is wrapped by Vaddy's own Go-style replacement expansion code.

The default compressible media type list in `src/encode.v` follows Caddy's
`modules/caddyhttp/encode/encode.go` at the same revision above and carries the
same Apache 2.0 notice. Encoder and event-loop code is implemented separately.
