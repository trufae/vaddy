# Third-party notices

The HTML redirect template in `src/redirect.v` (`html_redirect`) is adapted from
Caddy's `caddyconfig/httpcaddyfile/builtins.go`, revision
`8a6ab2b7bb3c6b83ed8d8031d6457375629858d8`. The surrounding implementation has been
rewritten in V.

Copyright 2015 Matthew Holt and The Caddy Authors.

That template is licensed under the Apache License, Version 2.0. A copy is
included in [licenses/Caddy-Apache-2.0.txt](licenses/Caddy-Apache-2.0.txt).

Vaddy also links to separately installed OpenSSL, RE2, zlib, nghttp2 and the platform C++
runtime. Their packages carry their respective licenses and notices. RE2
matching is wrapped by Vaddy's own Go-style replacement expansion code.
