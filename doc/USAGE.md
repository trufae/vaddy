# Using Vaddy

Run the commands in this guide from the repository root. Configure the site
hostname and upstream in [Caddyfile](../Caddyfile) before starting the server.
The checked-in hostname, `example.org`, is a placeholder for a domain you control.

## Build and run

Dependencies: a recent V compiler with `json2`, a C compiler, `pkg-config`,
OpenSSL 3 development libraries, and the `openssl` executable. Tested with
V `0.5.2 b7b4dd4` on arm64 macOS. The event backend uses epoll on Linux, kqueue
on macOS/BSD, and Winsock polling on Windows. See [platform builds and CI](BUILDING.md)
for the pinned compiler, Windows setup, Alpine output, and validation coverage.

```sh
make
./vaddy validate --config ./Caddyfile
sudo ./vaddy run --config ./Caddyfile --data /var/lib/vaddy
```

The default build uses optimization and Boehm GC. Keep GC enabled: request
metadata relies on collection. On macOS the Makefile prefers Homebrew's
OpenSSL 3 keg over older `pkg-config` entries. Override `V`, `VFLAGS`, or
`PKG_CONFIG_PATH` as needed. `VADDY_OPENSSL` selects the OpenSSL executable.

On Linux, an alternative to running as root is to grant the built executable
`cap_net_bind_service` and run under a dedicated user with a writable data
directory. Reapply capabilities after replacing the binary:

```sh
sudo setcap cap_net_bind_service=+ep ./vaddy
./vaddy run --config ./Caddyfile --data ./.vaddy-data
```

Stop the existing Caddy listener before starting Vaddy on the same ports. Your
backend must be reachable at `localhost:8001`. The default `::` listener accepts
both IPv6 and IPv4 on supported systems; use `--bind 0.0.0.0` for IPv4-only hosts.
Upstream names are resolved at startup, preferring IPv4. A backend address change
requires a restart.

`./vaddy --help` lists port, worker, connection-limit, timeout, storage, and staging
options. `SIGINT`/`SIGTERM` stop new accepts, drain active requests for up to ten
seconds, then close remaining connections. Configuration changes require a
restart; certificate updates do not.

## Automatic HTTPS

Bare site names enable ACME HTTP-01 with Let's Encrypt by default. Both public
TCP ports **80 and 443** must reach Vaddy, and the site's DNS A/AAAA records must
point to it. A configured AAAA record must also reach this server. A different
local port needs an external port mapping; changing `http_port` does not change
the CA's HTTP-01 validation port.

Vaddy binds both listeners before starting issuance. Port 80 serves active
`/.well-known/acme-challenge/…` requests and sends other site requests to HTTPS
with status 308. TLS connections are closed until a usable certificate has been
obtained; existing valid stored certificates load at startup.

The certificate worker:

- Creates and persists an RSA-2048 ACME account key, using RS256 signed requests,
  fresh nonces, bad-nonce retry, and POST-as-GET.
- Creates an ECDSA P-256 leaf key and a certificate covering the configured HTTPS
  hostnames. All HTTPS sites must share the same TLS policy.
- Checks renewal hourly and renews when one third of the certificate lifetime
  remains. Failures retry with backoff from one minute to one hour while the
  existing certificate continues serving.
- Publishes certificate/key generations through an atomic manifest replacement.
  The reactor loads the new TLS context without interrupting existing connections.
- Locks the data directory against another Vaddy writer. Directories are private
  on POSIX and newly created files use mode 0600. Windows uses inherited ACLs;
  choose a private user/service data directory. Account storage is scoped to the ACME CA;
  issuer/configuration metadata prevents accidental certificate reuse across CAs.

Starting an ACME configuration registers an account with agreement to the chosen
CA's terms. An email is optional:

```caddyfile
{
    admin off
    email admin@example.org
}
```

Use `--staging` for public ACME testing. It selects Let's Encrypt staging and a
separate `staging/` data directory; staging certificates are not browser-trusted.
The global `acme_ca` option supports another ACME directory. HTTP directory URLs
are permitted only on loopback for tests. ACME HTTPS verifies CA certificates and
hostnames. DNS-01, TLS-ALPN-01, wildcard certificates, EAB, issuer fallback, ARI,
and distributed storage are not implemented.

For local development, uncomment `tls internal` or use:

```caddyfile
localhost {
    tls internal
    reverse_proxy localhost:8001
}
```

This creates a private local CA at `DATA/pki/root.crt` and automatically renews
leaf certificates. It does not modify the OS trust store. Trust that root
explicitly, for example with `curl --cacert DATA/pki/root.crt …`.
`tls /path/fullchain.pem /path/key.pem` loads an externally managed certificate;
Vaddy watches for changes but does not renew manual certificates.

## Resource use

The request path defaults to one event-loop thread, with epoll/kqueue readiness
notifications and no thread per connection. `--workers N` enables up to 64
reactors, distributing new connections among them; each connection and its
buffers stay on one worker. More workers can increase throughput, with extra CPU
and memory costs: measure your workload before choosing a count. The connection
limit is global across workers. Certificate work runs on one background thread;
OpenSSL subprocesses are used only for infrequent certificate
and signing operations, never for proxied traffic. The garbage collector may
also use helper threads.

Four lazy byte queues per connection each have a 32 KiB logical limit. Bodies
stream without accumulating in memory; headers are limited to 16 KiB/128 fields,
chunk lines to 4 KiB, and trailers to 16 KiB. Allocator capacity, parsed headers,
OpenSSL, GC, and kernel socket buffers add overhead beyond these queue limits.
The default maximum is 512 clients, with at most one upstream socket each.
`--max-connections` lets you trade concurrency for memory. The reactor sleeps
between readiness events and checks timeouts/certificate publication once per
second. Accepts pause at capacity or on descriptor exhaustion to avoid a busy loop.

The optimized macOS binary measured approximately 808 KiB during development
(shared OpenSSL/GC libraries are additional). The [benchmark results](BENCHMARKS.md)
include a local TCP/TLS comparison with Caddy; it is not a production capacity test.

## HTTPS backends

Use `reverse_proxy https://backend.example:8443` to encrypt the connection to
an app. Upstream TLS uses TLS 1.2 or newer, verifies the certificate chain and
DNS name/IP address, and sends SNI for DNS names. HTTP/1.1 streaming, uploads,
WebSockets and per-client keep-alive work over TLS too. HTTPS upstreams receive
the upstream address as `Host`; `X-Forwarded-Host` keeps the original host.

System OpenSSL trust roots are used by default. For a private CA or a backend
reached by IP with a DNS certificate, configure:

```caddyfile
localhost {
    tls internal
    reverse_proxy https://127.0.0.1:8443 {
        transport http {
            tls_server_name backend.internal
            tls_trust_pool file /path/to/backend-ca.pem
        }
    }
}
```

The explicit CA file replaces the default trust roots for that route. Certificate
verification cannot be disabled. A failed handshake returns 502 without sending
the HTTP request to the backend. The header timeout also bounds upstream TLS
handshakes. Trust-file changes take effect on restart.

## Request and response headers

`header` changes response headers; `request_header` changes the headers sent to
the app. Both work at site level and inside `handle` blocks, in inline or block
form. A `reverse_proxy` block also accepts `header_up` and `header_down`.

```caddyfile
example.org {
    header {
        X-Content-Type-Options nosniff
        -Server
        ?Cache-Control no-cache
        +X-Tag vaddy
    }
    request_header -X-Debug
    reverse_proxy https://backend.example {
        header_up Host backend.example
        header_up X-Original-URI {uri}
        header_down -X-Powered-By
    }
}
```

A plain name replaces all existing values; `+Name` appends, `-Name` removes, and
`?Name` supplies a value only if absent. Names are case-insensitive. Site edits
run before route/proxy edits; edits within each list run in configuration order.
Request edits apply after automatic forwarding headers and HTTPS Host selection,
so explicit `header_up` settings can override them. Response edits also apply to
local redirects and errors when the site/route is known.

Values support `{uri}`, `{host}`, `{hostport}`, `{scheme}`, `{remote_host}` and
`{upstream_hostport}`. Substitution is a single pass; user-supplied values are
never expanded again. Regex replacements, header-name wildcards, matcher tokens
on header directives and deferred-header syntax are not supported. Use `handle`
for path-specific edits. Framing/connection headers cannot be edited, and request
`Host` can only be replaced. Output headers are limited to 16 KiB and 128 fields.

## Custom redirects

```caddyfile
example.org {
    redir /old/* https://new.example{uri} permanent
    handle /login {
        redir https://accounts.example/login 303
    }
    reverse_proxy localhost:8001
}
```

`redir [matcher] target [code]` accepts exact paths, trailing `*` paths or named
path matchers. With no matcher it redirects every request, so a site may consist
only of `redir`. The default is 302 (`temporary`); `permanent` means 301. Explicit
301, 302, 303, 307 and 308 codes are supported. Top-level redirects run before
proxy/handle routes, following Caddy's directive ordering. Inside a `handle`, put
the matcher on the handle and choose either a redirect or proxy as its action.

Targets use the same request placeholders as headers. Include `{uri}` to retain
the original path and query; a fixed target does not automatically copy them.
Redirects have an empty body, including for HEAD, and do not contact the backend.
HTML redirects and arbitrary status-code placeholders are not supported.
