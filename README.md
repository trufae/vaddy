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

A snapshot from the **November 11, 2026** benchmark: 32 concurrent clients,
512-byte proxy responses, HTTP/1.1 over TLS 1.3, on a shared macOS arm64 host
with 10 logical CPUs. Values are medians of three 10-second runs.

| Measurement | Vaddy · 1 worker | Caddy · default settings |
| --- | ---: | ---: |
| Throughput | **21,991 req/s** | 28,028 req/s |
| CPU under load¹ | **98.7%** | 361.2% |
| CPU time per request | **44.88 µs** | 128.86 µs |
| Idle memory (RSS) | **14.38 MiB** | 43.86 MiB |
| Sampled peak memory (RSS) | **38.70 MiB** | 67.16 MiB |

¹ 100% means one fully used CPU core. CPU and memory cover the server process only.
Vaddy defaults to one event-loop worker; `--workers N` enables more.
Caddy achieved higher total throughput in this run, using more CPU cores.
These are local measurements, not minimum hardware requirements or production
capacity estimates; compression and access logging were disabled.
See [benchmarks and methodology](doc/BENCHMARKS.md) for revisions, raw data and reproduction.

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
See [usage](doc/USAGE.md) for local TLS, custom ports and configuration examples.

## Explore

- [Usage](doc/USAGE.md) — configuration, certificates, workers and reloads.
- [Building](doc/BUILDING.md) — dependencies, platform builds and CI.
- [Testing](doc/TESTING.md) — integration tests and reproducible comparisons.
- [Performance lessons](doc/PERFLEARN.md) — profiling findings and implementation tradeoffs.

## License

[MIT](LICENSE) · Copyright © 2026 pancake.
Third-party components retain their own licenses; see [third-party notices](doc/THIRD_PARTY.md).
