# Caddy compatibility

Vaddy implements the Caddyfile features needed by this project. Unknown
directives fail validation. It does not implement Caddy's full module ecosystem.

| Feature | Implemented behavior |
| --- | --- |
| Global options | `admin off`, `http_port`, `https_port`, `email`, `acme_ca` |
| Site addresses | DNS hostnames, comma/space separated aliases, multiple sites; `http://name` opts out of TLS. Use global/CLI ports instead of address port suffixes. |
| Matchers | `@name path /a /prefix/*`; inline exact/trailing-wildcard `handle` matchers; case-insensitive, unescaped, normalized path matching |
| Routing | Mutually exclusive `handle` blocks, single-path specificity sorting, unmatched fallback |
| Redirects | `redir [path or @matcher] target [301/302/303/307/308/permanent/temporary]`; redirect-only sites and redirects inside `handle` |
| Rewriting | `rewrite * /target`, including `{uri}` and preserved query strings |
| Headers | `header`, `request_header`, proxy `header_up`/`header_down`; set, append, remove and set-if-absent operations; repeated fields preserved |
| Proxy | One HTTP/HTTPS upstream per route, verified TLS, preserved HTTP Host (HTTPS uses the upstream Host), regenerated X-Forwarded-For/Host/Proto, hop-by-hop header removal |
| HTTP | HTTP/1.1, HTTP/1.0 clients with connection close, keep-alive, sequential pipelining, HEAD, informational responses, length/chunked bodies, EOF-delimited responses |
| Streaming | Bounded upload/download queues, backpressure, SSE, WebSocket upgrades |
| TLS | OpenSSL TLS 1.2+, automatic public/internal certificates, live context replacement |
| Access logs | Per-site `log`, JSON lines to stderr/stdout or an append-only file; request status, timing, bytes and completion |
| CLI | `run`, `validate`, `version`, `--config`, `--adapter caddyfile` |

Not implemented: HTTP/2 or HTTP/3, dynamic DNS refresh, balancing,
shared upstream connection pools, request retries, compression, file serving,
imports/snippets/environment interpolation, arbitrary placeholders or matchers,
JSON configuration, the admin API, and Caddy plugins. Upstream
connections are reused per client while both sides permit it; failed requests
are not replayed. Header removal applies to response headers, not trailer fields.
Local IP-address certificate subjects are not supported; use DNS names such as
`localhost` with `tls internal`.
