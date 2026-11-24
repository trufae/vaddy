<div align="center">

# Vaddy

**Small footprint. Automatic HTTPS. Written in V.**

[![Build and test](https://github.com/trufae/vaddy/actions/workflows/ci.yml/badge.svg)](https://github.com/trufae/vaddy/actions/workflows/ci.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Releases](https://github.com/trufae/vaddy/releases) · [Getting started](doc/INSTALL.md) · [Feature parity](doc/COMPATIBILITY.md) · [Benchmarks](doc/BENCHMARKS.md)

</div>

Vaddy is a small web server and streaming reverse proxy written in [V](https://vlang.io/),
inspired by [Caddy](https://caddyserver.com/). It brings Caddyfile configuration,
automatic HTTPS and low resource use to a focused set of everyday hosting tasks.

- **HTTPS out of the box** — automatic certificates and renewal, local development
  certificates, and verified HTTPS backends.
- **Serve and stream** — static files, HTTP/2, gzip and Zstandard, WebSockets and SSE.
- **Route and operate** — path routing, rewrites, redirects, header editing,
  access logs and transactional configuration reloads.

Vaddy implements a subset of Caddy. The [feature-parity checklist](doc/COMPATIBILITY.md)
tracks supported behavior and remaining gaps, including HTTP/3, load balancing
and Caddy's module ecosystem. Unsupported directives fail validation.

## Light on resources

The **November 24, 2026** benchmark used 32 concurrent clients and 512-byte
proxy responses over HTTP/1.1 with TLS 1.3 on a shared macOS arm64 host with
10 logical CPUs. Values are medians of three four-second runs.

| Measurement | Vaddy · 1 worker | Vaddy · 2 workers | Caddy · default settings |
| --- | ---: | ---: | ---: |
| Throughput | 20,927 req/s | 31,050 req/s | 24,698 req/s |
| CPU under load¹ | 97.0% | 176.5% | 306.9% |
| CPU time per request | 46.34 µs | 56.55 µs | 128.29 µs |
| Idle memory (RSS) | 13.88 MiB | 19.73 MiB | 44.11 MiB |
| Sampled peak memory (RSS) | 30.52 MiB | 30.56 MiB | 68.03 MiB |

¹ 100% means one fully used CPU core. CPU and memory cover the server process only.
Vaddy defaults to four event-loop workers. Set `--workers N` to choose a count.
Compression and access logging were disabled. [Benchmark methodology and raw data](doc/BENCHMARKS.md#proxy-scaling-after-allocation-reductions-2026-11-24)

## Get started

Find builds for Linux, Alpine, macOS and Windows on the
[releases page](https://github.com/trufae/vaddy/releases).
Follow the [installation guide](doc/INSTALL.md) for your platform, or
[build from source](doc/BUILDING.md) with `make`.

Save a `Caddyfile` with your domain and backend:

```caddyfile
example.org {
    reverse_proxy localhost:8001
}
```

```sh
./vaddy validate --config Caddyfile
./vaddy run --config Caddyfile --data ./data
```

For public HTTPS, point your domain's DNS at the server and allow incoming TCP
ports **80 and 443**, with permission for Vaddy to bind them.
For HTTP without a hostname, use `:1234` as the site address; it serves all hosts
on that port without automatic HTTPS.
See [usage](doc/USAGE.md) for local TLS, custom ports and configuration examples.

## Explore

- [Usage](doc/USAGE.md) — configuration, certificates, workers and reloads.
- [Building](doc/BUILDING.md) — dependencies, platform builds and CI.
- [Testing](doc/TESTING.md) — integration tests and reproducible comparisons.
- [Performance lessons](doc/PERFLEARN.md) — profiling findings and implementation tradeoffs.

## License

[MIT](LICENSE) · Copyright © 2026 pancake.
Third-party components retain their own licenses; see [third-party notices](doc/THIRD_PARTY.md).
