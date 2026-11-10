# Vaddy

**Automatic HTTPS. Streaming reverse proxy. Written in V.**

[Usage](doc/USAGE.md) · [Compatibility](doc/COMPATIBILITY.md) ·
[Benchmarks](doc/BENCHMARKS.md) · [Performance lessons](doc/PERFLEARN.md) ·
[Testing](doc/TESTING.md)

Vaddy is a small reverse proxy with Caddyfile configuration, automatic TLS,
and a focus on low CPU and memory use. It implements a focused subset of Caddy;
unsupported directives fail validation.

| Feature | What you get |
| --- | --- |
| Automatic HTTPS | HTTP on **80**, HTTPS on **443**, ACME HTTP-01 and certificate renewal |
| Routing | Path matchers, asset rewrites, query preservation and response-header removal |
| Streaming | Bounded buffers, backpressure, SSE and WebSocket upgrades |
| Concurrency | epoll/kqueue reactors, optional workers and a global connection limit |
| Certificates | Public ACME, a local development CA, manual certificates and live reload |

## Get started

Requires V, a C compiler, `pkg-config`, OpenSSL 3 development libraries, and the
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

The initial TCP/TLS comparison showed lower CPU and memory use than Caddy, with
Caddy ahead in aggregate throughput at 32 clients. Subsequent Vaddy optimizations
improved the separate TLS socket-pair benchmark by **10%** with **11.5% less CPU
per request**. A fresh TCP comparison is needed to measure the current gap.

[Read the measurements and methodology →](doc/BENCHMARKS.md)

## Development

```sh
make test          # HTTP, routing, streaming, TLS, workers and mock ACME
make integration   # Loopback TCP/TLS integration tests
make compare       # Build ./caddy and compare both servers
```

The server runs natively in V with small POSIX/OpenSSL adapters. Go is used only
by the comparison tools and the Caddy reference build. HTTP/2, HTTP/3 and Caddy's
full module ecosystem are outside the current scope; see
[compatibility](doc/COMPATIBILITY.md).

Implementation details, reproducible benchmarks and optimization findings live
in [doc/](doc/). Start with [PERFLEARN.md](doc/PERFLEARN.md) when continuing
performance work.
