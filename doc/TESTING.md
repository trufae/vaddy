# Testing and benchmarking

Run these commands from the repository root. See [benchmark results](BENCHMARKS.md)
for recorded measurements and [performance lessons](PERFLEARN.md) for the
reasoning behind the optimizations.

[GitHub Actions](../.github/workflows/ci.yml) runs the V suite and real TCP/TLS
integration test on Linux, macOS and Windows. An additional job builds and tests
Alpine x86-64 using `make alpine`. See [build instructions](BUILDING.md) for the
toolchain pins and details of each job.

The Caddy and Raddy reference checkouts are separate from this repository and
ignored by Git. To prepare them for `make compare` on a fresh checkout:

```sh
git clone https://github.com/caddyserver/caddy ./caddy
git clone https://github.com/fokx/raddy ./raddy
# Optional: match the source revision used in the archived baseline.
git -C caddy checkout 8a6ab2b7bb3c6b83ed8d8031d6457375629858d8
```

The comparison tools require Go, plus Rust/Cargo, CMake and a C/C++ compiler for
Raddy. Raddy is built with `cargo build --release --locked --bin raddy` using its
checked-in dependency lockfile. Use the recorded revisions when reproducing a
measurement, or record the revisions you choose when measuring another version.
To update Raddy later, run `git -C raddy pull --ff-only` before rebuilding.

```sh
make test          # parser, framing, real socket-pair proxy I/O, TLS, mock ACME
make integration   # TCP/TLS, verified HTTPS backends, concurrent logs and live reloads
make bench         # optimized socket-pair request-path microbenchmark
make bench-workers # separate-process TLS socket-pair comparison of 1/2 workers
make compare       # build ./caddy and ./raddy; compare all three over TCP/TLS
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
settings when comparing Vaddy with Caddy and Raddy.

`make compare` builds Vaddy as needed, Caddy from `./caddy` as `./caddy-bench`,
and Raddy from `./raddy` in release mode as `./raddy-bench`, then runs
`tests/compare.py`. The harness uses the supplied routing rules, a separate Go
backend, a separate Go load process, 512-byte responses, HTTP/1.1 over TLS 1.3,
the same ECDSA certificate, 1 and 32 concurrent clients, and three ten-second
samples per server/concurrency combination. Server order rotates each repetition
so all three occupy each position once in the default run. It reports median throughput,
latency, server CPU time per request, CPU utilization, idle RSS, and sampled peak
RSS, saving the raw results to `benchmark-results.json`. Startup, certificate
generation, backend, and client CPU are excluded from the load CPU measurement.
The benchmark disables certificate verification only in its client for the
generated self-signed test certificate. Use `--plain` to compare cleartext HTTP:

```sh
make caddy-bench raddy-bench
python3 tests/compare.py --seconds 10 --runs 3
python3 tests/compare.py --plain --concurrency 1,32,128 --output benchmark-http.json
# Select a subset, including the original two-server comparison:
python3 tests/compare.py --servers caddy vaddy
# Supply an alternate release binary:
python3 tests/compare.py --raddy ./raddy/target/release/raddy
```

Raddy's generated Caddyfile adds `order header after handle`: its current header
handler runs eagerly, so the default ordering leaves upstream response headers
intact. This override makes it perform the same header removals as Caddy and
Vaddy. The harness records the override in JSON and still rejects any sample
with a wrong rewritten path, status, response size, or remaining header. The
Raddy checkout itself is unmodified. Failed warmups or measured samples are saved
with `valid: false` and diagnostics. The harness stops at the first failure and
exits nonzero, because resource exhaustion can affect later servers on the same
host. Failed or incomplete groups have no reported median. Error responses are
never counted as successful throughput.

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
`src/acme.v`. `src/platform.h` and its OS headers provide the OS/OpenSSL adapters; routing,
framing, streaming, certificate policy, and ACME logic are written in V.

Protocol references: [ACME RFC 8555](https://www.rfc-editor.org/rfc/rfc8555),
[Caddy automatic HTTPS](https://caddyserver.com/docs/automatic-https), and
[OpenSSL nonblocking I/O](https://docs.openssl.org/3.0/man3/SSL_read/).

`tests/upstream.py` verifies private-CA HTTPS backends, SNI/Host behavior,
streaming and keep-alive with two workers. Untrusted, wrong-name and mismatched
IP-address certificates must return 502. All certificates are generated locally.

`tests/reload.py` exercises one and three workers: backend replacement, updated
headers/redirects, keep-alive reuse, active streaming responses and WebSocket
sessions across reloads, POSIX SIGHUP, repeated generations, and rollback for
invalid syntax, inaccessible log destinations, missing trust roots and listener
changes. The original integration suite also verifies concurrent JSON access logs.
The V socket-pair suite checks header edit bounds, redirect ordering, per-request
logs, interrupted responses and lifetime management of retired configurations.
