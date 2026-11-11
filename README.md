# Vaddy

**Automatic HTTPS. Streaming reverse proxy. Written in V.**

[Usage](doc/USAGE.md) · [Builds & CI](doc/BUILDING.md) · [Compatibility](doc/COMPATIBILITY.md) ·
[Benchmarks](doc/BENCHMARKS.md) · [Performance lessons](doc/PERFLEARN.md) ·
[Testing](doc/TESTING.md)

Vaddy is a small reverse proxy with Caddyfile configuration, automatic TLS,
and a focus on low CPU and memory use. It implements a focused subset of Caddy;
unsupported directives fail validation.

| Feature | What you get |
| --- | --- |
| Automatic HTTPS | HTTP on **80**, HTTPS on **443**, ACME HTTP-01 and certificate renewal |
| Routing | Path matchers, rewrites, custom redirects and request/response header editing |
| Backends | HTTP and verified HTTPS, custom CA roots and TLS server names |
| Operations | JSON access logs and transactional configuration reloads |
| Streaming | Bounded buffers, backpressure, SSE and WebSocket upgrades |
| HTTP/2 | Automatic TLS negotiation, concurrent streams and flow control |
| Compression | Streaming gzip and Zstandard, negotiation and cache headers |
| Static websites | Document roots, indexes, directory listings, byte ranges and cache validation |
| Concurrency | epoll/kqueue/Windows polling, optional workers and a global connection limit |
| Certificates | Public ACME, a local development CA, manual certificates and live reload |

## Get started

Requires V, C and C++17 compilers, `pkg-config`, OpenSSL 3, RE2, zlib, nghttp2 and Zstandard development libraries, and the
`openssl` executable. The default build uses Clang and Boehm GC.

Configure your domain and backend in [Caddyfile](Caddyfile). A minimal site looks
like this; replace `example.org` with your own domain:

```caddyfile
example.org {
    reverse_proxy localhost:8001
}
```

```sh
make
./vaddy validate --config ./Caddyfile
sudo ./vaddy run --config ./Caddyfile --data /var/lib/vaddy
```

For public certificates, point the domain's DNS at the server and make TCP ports
**80 and 443** reachable. Stop any existing listener on those ports first.
See the [usage guide](doc/USAGE.md) for local TLS, port permissions, staging,
worker counts and certificate storage.

## Performance

The latest optimizations improved median TCP/TLS throughput by **12.0%** and
reduced CPU per request by **11.0%** at 32 clients versus the preceding feature
build. Idle memory fell from **20.5 to 14.4 MiB**, and sampled peak memory from
**40.9 to 38.7 MiB**. A 64 KiB response check also improved throughput by **13.4%**.
All 2.88 million measured requests passed. Vaddy still used less CPU and memory
than the Caddy reference, while Caddy delivered more aggregate throughput.
These are short local HTTP/1.1 proxy measurements with compression and logging
disabled; the HTTP/2, compression, file-serving and log compatibility tests pass.

The comparison also builds Raddy in release mode. Its current upstream build
hits connection-allocation failures under sustained load on the measured macOS
host, so no valid Raddy performance ranking is reported.

[Read the measurements and methodology →](doc/BENCHMARKS.md)

## Development

```sh
make test          # HTTP, routing, streaming, TLS, workers and mock ACME
make integration   # TCP/TLS, HTTPS backends, access logs and live reloads
make compare       # Build ./caddy and ./raddy; compare all three servers
make alpine        # Build/test Alpine x86-64; export dist/vaddy-alpine-x86_64
```

GitHub Actions builds and tests Linux, macOS and native Windows, plus the Alpine
target. See [build instructions](doc/BUILDING.md) for toolchains and dependencies.

The server runs natively in V with small OS/OpenSSL adapters. Go is used only
by the comparison tools and the Caddy reference build; Rust/Cargo builds the
Raddy reference. See [benchmark setup](doc/TESTING.md) for both checkouts.
HTTP/3, HTTP/2 backends and Caddy's
full module ecosystem remain unsupported; see
[compatibility](doc/COMPATIBILITY.md).

Implementation details, reproducible benchmarks and optimization findings live
in [doc/](doc/). Start with [PERFLEARN.md](doc/PERFLEARN.md) when continuing
performance work.
