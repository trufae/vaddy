# Testing and benchmarking

Run these commands from the repository root. See [benchmark results](BENCHMARKS.md)
for recorded measurements and [performance lessons](PERFLEARN.md) for the
reasoning behind the optimizations.

The Caddy reference checkout is separate from this repository and is ignored by
Git. To prepare it for `make compare` on a fresh checkout:

```sh
git clone https://github.com/caddyserver/caddy ./caddy
# Optional: match the source revision used in the archived baseline.
git -C caddy checkout 8a6ab2b7bb3c6b83ed8d8031d6457375629858d8
```

The comparison tools also require Go. Use the recorded revision when reproducing
the baseline, or record the revision you choose when measuring another version.

```sh
make test          # parser, framing, real socket-pair proxy I/O, TLS, mock ACME
make integration   # real loopback TCP/TLS against a local backend
make bench         # optimized socket-pair request-path microbenchmark
make bench-workers # separate-process TLS socket-pair comparison of 1/2 workers
make compare       # build ./caddy and compare both servers over real TCP/TLS
```

The V suite verifies the supplied Caddyfile routes, query preservation, malformed
framing rejection, chunk fragmentation, duplicate response headers, pipelining,
large streaming bodies, WebSockets, TLS backpressure, local CA trust, certificate
replacement during a live TLS connection, HTTP-01 serving, and signed ACME
account/order/finalization with bad-nonce retry and persisted keys. The ACME mock
independently verifies JWS signatures and signs the real CSR. It substitutes only
the CA HTTP transport; it does not contact a public CA.

The development sandbox allowed anonymous socket pairs but denied listening TCP
sockets. The V suite ran successfully there. `tests/integration.py` is provided
for a host that permits loopback listeners. The user subsequently ran
`make compare`, verifying real TCP/TLS and the measured rewrite/header-removal
path. Live public issuance, port 80/443 binding, and the separate full integration
suite still need deployment verification.
The microbenchmark measures one process driving both ends of socket pairs, not
internet throughput; use the same backend, response sizes, concurrency, and TLS
settings when comparing Vaddy with Caddy.

`make compare` builds Caddy from `./caddy` as `./caddy-bench` and runs
`tests/compare.py`. The harness uses the supplied routing rules, a separate Go
backend, a separate Go load process, 512-byte responses, HTTP/1.1 over TLS 1.3,
the same ECDSA certificate, 1 and 32 concurrent clients, and three ten-second
samples per server/concurrency combination. It reports median throughput,
latency, server CPU time per request, CPU utilization, idle RSS, and sampled peak
RSS, saving the raw results to `benchmark-results.json`. Startup, certificate
generation, backend, and client CPU are excluded from the load CPU measurement.
The benchmark disables certificate verification only in its client for the
generated self-signed test certificate. Use `--plain` to compare cleartext HTTP:

```sh
make caddy-bench
python3 tests/compare.py --seconds 10 --runs 3
python3 tests/compare.py --plain --concurrency 1,32,128 --output benchmark-http.json
```

The user downloaded Caddy's Go dependencies and completed the comparison.
The [benchmark results](BENCHMARKS.md) record the verified medians, raw sample
archive, and limitations. At 32 clients, Vaddy used less CPU per request and
memory, while Caddy delivered higher aggregate throughput.

Subsequent request-path optimizations improved the one-worker TLS socket-pair
benchmark by 10.0%, with 11.5% less CPU per request and similar peak RSS. These
are separate measurements from the original TCP comparison. Rerun the latter
to assess the current build, optionally enabling a second worker:

```sh
make compare COMPARE_ARGS='--output benchmark-results-optimized.json'
make compare COMPARE_ARGS='--vaddy-workers 2 --output benchmark-results-workers2.json'
```

Core implementation: `src/config.v`, `src/http.v`, `src/server.v`, `src/workers.v`, and
`src/acme.v`. `src/platform.h` is a small POSIX/OpenSSL ABI adapter; routing,
framing, streaming, certificate policy, and ACME logic are written in V.

Protocol references: [ACME RFC 8555](https://www.rfc-editor.org/rfc/rfc8555),
[Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https), and
[OpenSSL nonblocking I/O](https://docs.openssl.org/3.0/man3/SSL_read/).
