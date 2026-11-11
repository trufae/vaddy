# Caddy compatibility

Vaddy implements the Caddyfile features needed by this project. Unknown
directives fail validation. It does not implement Caddy's full module ecosystem.

| Feature | Implemented behavior |
| --- | --- |
| Global options | `admin off`, `http_port`, `https_port`, `email`, `acme_ca` |
| Site addresses | DNS hostnames, comma/space separated aliases, multiple sites; `http://name` opts out of TLS. Use global/CLI ports instead of address port suffixes. |
| Matchers | `@name path /a /prefix/*`; inline exact/trailing-wildcard `handle` matchers; case-insensitive, unescaped, normalized path matching |
| Routing | Mutually exclusive `handle` blocks, single-path specificity sorting, unmatched fallback |
| Redirects | `redir [path or @matcher] target [3xx/401/permanent/temporary/html/placeholder]`; redirect-only sites and redirects inside `handle` |
| Rewriting | `rewrite * /target`, including `{uri}` and preserved query strings |
| Headers | `header`, `request_header`, proxy `header_up`/`header_down`; set/append/delete, response defaults/defer, RE2 replacements, wildcard deletion, path and response conditions |
| Proxy | One HTTP/HTTPS upstream per route, verified TLS, preserved HTTP Host (HTTPS uses the upstream Host), regenerated X-Forwarded-For/Host/Proto, hop-by-hop header removal |
| HTTP | HTTP/2 over TLS with ALPN, concurrent streams and flow control; HTTP/1.1, HTTP/1.0 clients with connection close, keep-alive, sequential pipelining, HEAD, informational responses, length/chunked bodies, EOF-delimited responses |
| Streaming | Bounded upload/download queues, backpressure, SSE, WebSocket upgrades |
| Compression | `encode [path/@matcher] [zstd gzip]`, levels, `minimum_length`, status/header response matching, negotiation, cache headers and incremental streaming over HTTP/1 and HTTP/2 |
| TLS | OpenSSL TLS 1.2+, automatic public/internal certificates, live context replacement |
| Access logs | Named JSON/console logs, filters, custom fields, levels and path-based skipping; stderr/stdout/discard/files; file rotation, gzip and retention; Caddy-style metadata/body counts |
| Reload | Transactional request-setting reloads through `vaddy reload` or POSIX SIGHUP; active requests keep their configuration; ports and certificate policies require restart |
| CLI | `run`, `reload`, `validate`, `version`, `--config`, `--adapter caddyfile` |

## Remaining compatibility checklist

The table above describes supported use cases, not complete 1:1 compatibility.
The unchecked items below track missing capabilities and differences in behavior.
Refer to an item by its `CADDY-NNN` ID in issues, commits or discussions. Keep IDs
stable: do not renumber or reuse them. Check an item when its stated scope is
implemented and verified against Caddy; split partially completed items into new
IDs when needed, retaining a reference from the original item.

This is a checklist of the identified gaps, not an exhaustive inventory of every
Caddy option or community plugin. Some differences are deliberate restrictions;
tracking them here does not imply that removing those restrictions is desirable.

### HTTPS backends

- [ ] **CADDY-001 — Upstream TLS client authentication:** present client
  certificates to backends, including Caddy's certificate-management options.
- [ ] **CADDY-002 — Transport configuration:** support the remaining HTTP/TLS
  transport controls, including TLS versions/ciphers, trust providers, verification
  settings, and separate connection, handshake, read and write timeouts.

### Header editing

- [ ] **CADDY-003 — Header execution semantics:** match Caddy's immediate and
  deferred operations, including `defer`/`>` syntax and interactions between site,
  route and proxy edits. Implemented and verified for supported routes in CADDY-052;
  nested routing and informational-response edge cases still need coverage.
- [ ] **CADDY-004 — Header transformations:** support regex value replacements
  and wildcard header names. Implemented with RE2 and Go-style substitutions;
  resource limits and uncommon Go/RE2 dialect differences remain to audit (CADDY-053).
- [ ] **CADDY-005 — Conditional headers:** support matcher tokens directly on
  header directives and response conditions in header blocks. Path matchers and
  status/header response conditions are implemented; broader request matcher types
  depend on CADDY-026.
- [ ] **CADDY-006 — Header restrictions and trailers:** account for differences
  caused by Vaddy's protected framing/connection headers, lack of trailer editing. Request `Host` set/append/delete now match Caddy. Preserve valid HTTP framing when extending
  this behavior.

### Redirects

- [ ] **CADDY-007 — Full redirect behavior:** support HTML redirects, status-code
  placeholders and Caddy's remaining accepted codes. Standard forms are implemented
  and compared in CADDY-051. Remaining: dynamic informational/nonstandard status
  codes outside 200–599 and placeholders supplied by unsupported Caddy modules.

### Logging

- [ ] **CADDY-008 — Access-log schema:** match Caddy's JSON fields, structure,
  units and byte accounting. Normal HTTP/1 cases are verified in CADDY-054.
  Remaining: write-error fields, upgraded connections, abort timing, and metadata
  for unsupported protocols/authentication/trusted proxies.
- [ ] **CADDY-009 — Log destinations and rotation:** add file rotation, retention,
  network outputs and other standard output options beyond stderr/stdout/files.
  File size/interval rotation, gzip, retention and discard are implemented in
  CADDY-055. Remaining: network writers, Zstandard, scheduled/time-based background
  rolling, custom backup layouts and directory-mode inheritance.
- [ ] **CADDY-010 — Log customization:** support named loggers, filtering,
  redaction, custom fields, conditional logging, levels and additional encoders.
  The supported subset is CADDY-056. Remaining: sampling, IP masking, nested
  encoder wrappers, arbitrary Go time layouts, body/variable capture, undeclared
  logger fallback, complete cookie parsing, and remaining encoder/module options.

### Reloads and configuration management

- [ ] **CADDY-011 — Listener reloads:** change listener ports and bind addresses
  without restarting. Vaddy currently rejects configured port changes.
- [ ] **CADDY-012 — HTTPS configuration reloads:** add/remove HTTPS hostnames and
  change certificate policies live. Even reordering the current HTTPS hostname
  list requires a restart in Vaddy.
- [ ] **CADDY-013 — Admin API:** implement Caddy-compatible configuration load,
  inspection, partial updates and control endpoints. Vaddy's reload command uses
  a private request/result exchange in the data directory instead.
- [ ] **CADDY-014 — JSON configuration and adapters:** support Caddy's native
  JSON configuration model and configuration-adapter workflow.
- [ ] **CADDY-015 — Configuration recovery:** save and resume the last working
  configuration, including changes applied through the API.

### Protocols and proxy operation

- [x] **CADDY-016 — HTTP/2 serving:** accept and serve HTTP/2 over TLS via ALPN.
  Multiplexed proxy requests, bounded upload/download queues, stream cancellation,
  flow control, request-generation reloads, graceful GOAWAY and HTTP/1 fallback.
  `make http2` uses an independent hyper-h2 client; the common wire cases also pass
  against Caddy `8a6ab2b7bb3c6b83ed8d8031d6457375629858d8`.
- [ ] **CADDY-017 — HTTP/3 serving:** accept and serve HTTP/3/QUIC client connections.
- [ ] **CADDY-018 — Additional backend protocols:** support HTTP/2/h2c and
  HTTP/2-based gRPC proxying, plus Caddy's HTTP/3 upstream option.
- [ ] **CADDY-019 — Unix socket backends:** support Caddy's Unix socket upstream
  addresses in addition to TCP host/port addresses.
- [ ] **CADDY-020 — Load balancing:** support multiple backends per route,
  selection policies, weights and sticky sessions.
- [ ] **CADDY-021 — Health checks:** support active and passive backend health
  checks and exclusion of unhealthy backends.
- [ ] **CADDY-022 — Retries and failover:** retry eligible requests and select
  alternate backends under configurable policies. Vaddy does not replay failures.
- [ ] **CADDY-023 — Shared connection pools:** reuse backend connections across
  clients. Current reuse is limited to each individual client connection.
- [ ] **CADDY-024 — Dynamic backend discovery:** refresh DNS periodically and
  discover changing backend lists. Current resolution occurs at startup/reload.
- [ ] **CADDY-025 — Trusted proxy handling:** support trusted proxy ranges and
  Caddy's client-IP/forwarded-header interpretation when another proxy is in front.

### Routing and Caddyfile language

- [ ] **CADDY-026 — Request matchers:** support header, method, IP, query,
  protocol, regex and expression matchers, combinations and negation beyond the
  current exact/trailing-wildcard path rules.
- [ ] **CADDY-027 — Directive matcher syntax:** accept matchers on supported
  directives wherever Caddy permits them. For example,
  `reverse_proxy /api/* localhost:8001` currently requires a `handle /api/*` block.
- [ ] **CADDY-028 — Routing composition and ordering:** support nested routes,
  `handle_path`, `route`, reusable named routes and Caddy's complete handler ordering.
- [ ] **CADDY-029 — URL and request manipulation:** support broader `rewrite`
  syntax, `uri`, `method` and `try_files`. Vaddy currently supports
  `rewrite * /target` inside proxy handles, with `{uri}` and query preservation.
- [ ] **CADDY-030 — Variables and placeholders:** support `vars`, `map` and the
  full placeholder system. Header/redirect/log values recognize common request
  placeholders, request headers and query values; module-generated placeholders
  and arbitrary variables remain incomplete.
- [ ] **CADDY-031 — Caddyfile reuse and parsing:** support imports, snippets,
  environment expansion and remaining lexical/structural forms, including
  single-site configurations without braces, backtick strings and heredocs.
- [ ] **CADDY-032 — Site addresses and global options:** support wildcard and
  IPv6 site addresses, per-site port syntax and the remaining global/server options.
  Vaddy currently uses hostname-based sites and global/CLI listener ports.

### Website serving and authentication

- [ ] **CADDY-033 — Static files:** implement file serving, directory browsing,
  range requests and cache validation.
- [x] **CADDY-034 — Compression:** streaming gzip and Zstandard for responses,
  with bounded queues and flow control. Negotiation, size thresholds,
  content types, HEAD, 206/304, existing encodings, no-transform, ETag variants and
  incremental SSE are compared with the pinned Caddy reference in `make encode`.
  Remaining tuning and edge cases are tracked in CADDY-058.
- [ ] **CADDY-035 — Templates:** implement response template rendering.
- [ ] **CADDY-036 — PHP and FastCGI:** implement FastCGI transport and
  `php_fastcgi` routing behavior.
- [ ] **CADDY-037 — HTTP authentication:** implement `basic_auth` and
  `forward_auth` checks against external authentication services.
- [ ] **CADDY-038 — Client certificate authentication:** authenticate incoming
  clients with certificates and configurable trust policies.

### HTTPS automation and local certificates

- [ ] **CADDY-039 — Per-site TLS policies:** select separate certificates and
  TLS policies for different sites. Current HTTPS sites share one policy.
- [ ] **CADDY-040 — DNS validation and wildcards:** implement DNS-01 challenges
  and wildcard certificate automation, with DNS provider integrations.
- [ ] **CADDY-041 — TLS challenge validation:** implement TLS-ALPN-01 alongside
  the existing HTTP-01 ACME challenge support.
- [ ] **CADDY-042 — On-demand certificates:** obtain certificates for newly
  encountered hostnames, with permission checks controlling issuance.
- [ ] **CADDY-043 — Issuer and renewal options:** implement issuer fallback,
  external account binding (EAB), CA-guided renewal (ARI) and remaining certificate
  issuance/renewal policy controls.
- [ ] **CADDY-044 — Distributed certificate storage:** coordinate certificate
  management across multiple server instances using shared storage.
- [ ] **CADDY-045 — Advanced TLS facilities:** support OCSP stapling, Encrypted
  ClientHello (ECH) and its publication, and the remaining TLS customization options.
- [ ] **CADDY-046 — Local trust and IP certificates:** install the local CA into
  supported trust stores and issue certificates with IP-address subjects. Vaddy
  currently requires explicit trust and DNS names such as `localhost`.

### Monitoring, responses and extensions

- [ ] **CADDY-047 — Metrics and tracing:** expose Prometheus metrics and
  OpenTelemetry tracing integrations.
- [ ] **CADDY-048 — Response and error handling:** support configurable fixed
  responses, custom error routes and response interception/manipulation.
- [ ] **CADDY-049 — Modules and plugins:** provide an extension system and
  account for compatibility with required Caddy modules. Community plugins are a
  separate, expanding scope rather than a finite built-in feature list.

### Compatibility verification

- [ ] **CADDY-058 — Remaining compression options:** exact codec output/level
  mapping (Vaddy uses zlib/libzstd), stateless gzip level, nested Zstandard options,
  complete content sniffing when upstream omits Content-Type, and Caddy's precise
  first-write threshold behavior. Vaddy accepts minimum_length up to 16384 bytes
  and buffers small unknown-length bodies up to that threshold. Compressed HTTP/1
  responses use chunked framing; Caddy may choose Content-Length for short output.

- [ ] **CADDY-057 — Additional HTTP/2 options:** cleartext HTTP/2 listeners (h2c),
  extended CONNECT/WebSockets over HTTP/2, forwarding/editing HTTP/2 trailers,
  and Caddy's protocol/server tuning options. Current limits are 64 concurrent
  streams per connection, the configured maximum request count, 16 KiB headers,
  and a global active-stream limit equal to `--max-connections`. HTTP/2 backends
  and gRPC remain CADDY-018. The wire engine adds a libnghttp2 dependency.

- [ ] **CADDY-050 — Differential test coverage:** run identical configurations
  and requests against Vaddy and Caddy, comparing accepted syntax, routing,
  headers, status/body output, logging and reload behavior. Current feature tests
  and selected comparisons do not establish complete Caddy equivalence. Record
  the Caddy version used when claiming compatibility.

### Verified steps

- [x] **CADDY-051 — Standard redirect forms (part of CADDY-007):** Caddy matcher
  extraction, all literal 3xx codes and 401, aliases, HTML template, request
  header/query status placeholders (200–599), HEAD, and connection reuse.
  `make compatibility` compares 15 configurations against Caddy
  `8a6ab2b7bb3c6b83ed8d8031d6457375629858d8` (2026-11-10). Unknown target
  placeholders are preserved. The broader placeholder gap remains CADDY-030.

- [x] **CADDY-052 — Header middleware and conditions (parts of CADDY-003–006):**
  immediate/deferred ordering, `defer`/`>`, defaults, wildcard deletion, operation
  phases, path matchers, response status/header conditions, and request Host edits.
  Compared with Caddy in 22 cases. Framing fields remain protected, including when
  deleting `*`; this deliberate restriction is not claimed as Caddy equivalence.

- [x] **CADDY-053 — Regex header replacements (part of CADDY-004):** numeric and
  named captures, literal dollars, global/empty matches, dynamic patterns and
  request/proxy/response edits. Uses RE2 with explicit memory/capture/output limits.
  This adds a C++17/RE2 build and runtime dependency; CI and Alpine package lists
  have been updated. Cross-platform jobs must still run on their target systems.

- [x] **CADDY-054 — Standard access-log schema (part of CADDY-008):** nested
  request/response headers, default credential redaction, seconds-based timestamps
  and durations, named logger identity, TLS details and decoded body byte counts.
  HTTP/1 redirects, HEAD, fixed/chunked responses and fixed/chunked uploads are
  compared with Caddy. Date/server/Via branding, timing and ephemeral ports are
  explicitly normalized by the comparison suite.

- [x] **CADDY-055 — File rotation and retention (part of CADDY-009):** default
  100 MiB rotation, gzip, backup count/age retention, file/directory modes,
  write-triggered intervals, disabled rotation, discard output, and parent creation.
  Tests verify compression, retention, unrelated-file preservation and overlapping
  generation writers. Compression is synchronous and interval timers are lazy;
  these scheduling differences remain explicitly outside the parity claim.

- [x] **CADDY-056 — Common log customization (part of CADDY-010):** multiple
  named destinations, `log_name`, `log_skip`, `log_level`, log thresholds,
  `log_append`, JSON/console output, constant encoder fields, and nested-field
  delete/rename/replace/hash/regexp/query/cookie filters. Differential cases cover
  named routing, skipping, severity, custom fields and common JSON filters.
  Cookie quoting and uncommon formatting variants are not claimed as full parity.

## Which remaining gaps are mandatory?

“Mandatory” depends on the promised deployment. No HTTP specification requires
implementing every Caddy module. For an unqualified **1:1 with Caddy** claim,
**every unchecked compatibility item is mandatory within the agreed Caddy version
and module set**; the completed sub-items above do not close their broader parents.

| Priority | IDs | When required |
| --- | --- | --- |
| 🔴 Required for the requested header/redirect/log parity | CADDY-003–010, CADDY-050 | Close the remaining semantics, options and differential coverage before calling these areas 1:1. |
| 🔴 Required for each release | CADDY-050, CADDY-006 | Verify supported behavior, malformed framing, streaming, concurrency and reloads. Keep framing protections until a safe replacement is tested. |
| 🟠 Required behind a CDN or another proxy | CADDY-025 | Correct client-IP and forwarded-header trust. |
| 🟠 Required with changing DNS backends | CADDY-024 | Refresh resolved addresses without a manual reload. |
| 🟠 Required when upstream SLAs need separate limits | CADDY-002 | Independent connect, TLS handshake, read and write timeouts. |
| 🟠 Required for multi-backend availability | CADDY-020–022 | Selection, unhealthy-backend exclusion and safe failover. |
| 🟡 Required only by the chosen workload | Other unchecked IDs | Examples: HTTP/2 upstreams for gRPC, authentication when Vaddy owns access control, static serving when it owns files, or distributed certificate storage across instances. |

Cross-platform CI must validate the new RE2/C++ and zlib dependencies. Local
macOS tests do not establish Linux, Windows or Alpine compatibility.
