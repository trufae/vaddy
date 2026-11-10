# Measurements obtained on 2026-11-10

## Raddy release integration

`make compare` now includes Caddy, Vaddy and Raddy. Raddy v0.9.0 was cloned from
`fokx/raddy` at `451fd9ffd1c9c7d951c7f86a09ec6a57e5db1625` and built, without
source changes, using `cargo build --release --locked --bin raddy`. The compiler
was Rust `1.100.0-beta.13 (3b0202dcd 2026-11-07)`; the resulting `raddy-bench`
is 26,982,448 bytes (25.73 MiB).

The workload remains HTTP/1.1 over TLS 1.3, the same ECDSA certificate, 512-byte
responses, the asset rewrite, and removal of both Cross-Origin headers. Raddy's
generated configuration adds `order header after handle` because its header
handler otherwise runs before the upstream response exists. This is recorded
in the JSON; response validation remains enabled for every request.

**No valid Raddy performance ranking is available on this host.** The default
ten-second load produces HTTP 502 responses with upstream connection errors:
`Can't assign requested address (os error 49)`. Raddy's
[HTTP transport opens a new upstream TCP connection for each request](https://github.com/fokx/raddy/blob/451fd9ffd1c9c7d951c7f86a09ec6a57e5db1625/crates/raddy-proxy/src/transport.rs#L288),
which is consistent with ephemeral-port exhaustion. The same failure occurs
with cleartext HTTP. Failed responses must not be presented as useful throughput.

This transient host resource exhaustion can also affect subsequent Caddy/Vaddy
samples. The harness therefore stops on the first failed warmup or measured
sample, saves its diagnostics, and exits nonzero. It does not print medians for
failed or incomplete groups. The final TLS attempt is
[archived here](../tests/benchmark-results-2026-11-10-raddy.json), including build
provenance. The historical valid Caddy/Vaddy baseline below is retained.

```sh
make raddy-bench
make compare  # includes Raddy; currently fails validation on this macOS host
# Run the original comparison independently, after TCP state has settled:
python3 tests/compare.py --servers caddy vaddy
```

## Caddy versus Vaddy: TCP/TLS baseline

The user ran `make compare` successfully after downloading Caddy's dependencies.
The saved JSON was checked against the summary below: all 12 samples completed,
with **1,811,455 successful requests and zero errors**. The raw baseline is
[archived here](../tests/benchmark-results-2026-11-10-baseline.json).

Environment and method:

- macOS 27.0.1, arm64. Caddy source commit `8a6ab2b7bb3c6b83ed8d8031d6457375629858d8`,
  compiled with Go 1.27.2 and `-trimpath -ldflags '-s -w'`.
- Vaddy built with V `0.5.2 b7b4dd4`, optimized Clang output and Boehm GC.
- HTTP/1.1 over TLS 1.3 on loopback, with the same manually supplied ECDSA P-256
  certificate. Certificate verification is disabled only in the benchmark client
  for this self-signed certificate; ACME issuance/renewal is not exercised.
- Separate Go backend and load-generator processes, 512-byte responses,
  `/assets/bench.js` rewritten to `/static/assets/bench.js`, and both configured
  Cross-Origin response headers removed. Successful requests verify status,
  response length, and header removal; the backend checks the rewritten path.
- Three ten-second samples per server/concurrency combination, with a fresh
  server process, a two-second idle observation and one-second warmup per sample.
  Server order alternates between repetitions. All processes share the host;
  cores are not pinned or limited.
- CPU/RSS cover the server process, excluding backend/load-generator processes.
  CPU is user + system time sampled around the measured load. 100% means one
  fully utilized core. RSS includes resident shared libraries; peak RSS is
  sampled every 100 ms rather than measured as an OS high-water mark.
- Each table entry is the median of its three samples. Latency is the median
  of the per-run mean latencies, not a request-latency percentile.

| Server | Clients | Requests/s | CPU | CPU/request | Mean latency | Idle RSS | Sampled peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Caddy | 1 | 5,631 | 103.0% | 182.93 µs | 0.177 ms | 43.8 MiB | 52.4 MiB |
| Vaddy | 1 | 7,832 | 39.2% | 50.05 µs | 0.128 ms | 7.5 MiB | 10.7 MiB |
| Caddy | 32 | 26,482 | 372.0% | 140.82 µs | 1.208 ms | 43.4 MiB | 67.3 MiB |
| Vaddy | 32 | 20,914 | 98.4% | 47.00 µs | 1.530 ms | 7.5 MiB | 12.7 MiB |

### Interpretation

Lower CPU time per request is better. Relative changes below are calculated
from the unrounded medians in the archived JSON:

- **One client:** Vaddy delivered 39.1% more requests/s, used 72.6% less CPU per
  request, and had 79.6% lower sampled peak RSS.
- **32 clients:** Caddy delivered 26.6% more requests/s than Vaddy. Vaddy used
  66.6% less CPU per request and had 81.2% lower sampled peak RSS, but delivered
  21.0% fewer requests/s and had 26.6% higher mean latency than Caddy.
- Vaddy's roughly one-core utilization at 32 clients is consistent with its
  single event-loop thread limiting aggregate throughput. Caddy used about 3.72
  cores. This is an architectural explanation to investigate, not proof from a
  CPU profile or an equal-core experiment.
- Both servers reported 0.0% idle CPU over the short observation window. This
  means no CPU time was resolved at the sampler's precision, not zero work.

At one client, throughput ranged from 4,899–5,669 requests/s for Caddy and
6,329–7,992 for Vaddy. At 32 clients the ranges were 26,208–27,195 and
20,885–21,094 respectively. These are short local tests of one route and payload;
they do not establish production capacity, long-term memory use, certificate
management cost, or performance for other body sizes/protocols. Caddy implements
many features outside Vaddy's current scope.

### Reproduce

```sh
make vaddy caddy-bench
python3 tests/compare.py --servers caddy vaddy
# Customize the original two-server workload after building both binaries:
python3 tests/compare.py --servers caddy vaddy --seconds 30 --runs 3 --concurrency 1,32,128 \
    --output benchmark-results-new.json
```

The harness is in `tests/compare.py` and `tests/bench_driver.go`. The source JSON
at the repository root can be overwritten by another run; the archived baseline
above is retained for comparisons with subsequent optimizations.

## Throughput optimization: separate-process TLS socket-pair measurements

The request path was profiled and optimized after the TCP baseline above:

- Avoid speculative reads from the other socket and repeated reads after EAGAIN,
  while continuing to drain TLS records already buffered by OpenSSL.
- Scan HTTP headers and tokens without temporary split/byte arrays, cache
  lowercase header names, and reuse each connection's header array.
- Write outgoing headers directly into reusable output buffers instead of
  allocating a builder, string, and byte-array copy for each message.
- Retain disabled descriptor entries until close, avoiding map deletion and
  reinsertion on every request. Skip path normalization when already normalized,
  and lowercase configured matchers once at startup.
- Add optional `--workers N` reactors with exclusive connection ownership,
  a global connection limit, and one certificate manager. The default remains
  **one worker** to preserve CPU and memory efficiency.

The sandbox still denies listening TCP sockets. `make bench-workers` therefore
uses anonymous Unix socket pairs: a separate Go driver supplies client/backend
I/O, and a child Vaddy process runs the actual event loops, TLS, parser and proxy.
Only listener setup is substituted. These are **Vaddy-before versus Vaddy-after
measurements, not another Caddy comparison**.

Workload: 32 clients, HTTP/1.1 over TLS 1.3, 512-byte responses, the same asset
rewrite and header removals, three five-second samples for each worker count,
alternating worker-count order. The before build already included the worker
pool; the table measures the subsequent request-path optimizations. Each entry
is the median of three samples.

| Request path | Workers | Requests/s | Server CPU/request | Server peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Before | 1 | 46,705 | 21.36 µs | 12.36 MiB |
| After | 1 | **51,394** | **18.91 µs** | **12.31 MiB** |
| Before | 2 | 45,798 | 36.95 µs | 14.63 MiB |
| After | 2 | **54,719** | **26.97 µs** | **14.61 MiB** |

With one worker, median throughput increased **10.0%** and CPU/request fell
**11.5%**, with essentially unchanged peak RSS. Two workers improved **19.5%**
over their own pre-optimization result. In the final build, two workers delivered
6.5% more throughput than one, but used 42.6% more CPU per request and about
2.3 MiB more peak RSS. Extra workers are a workload-dependent tradeoff.

The final one-worker range was 49,174–51,666 requests/s; two workers ranged from
54,172–55,047. All **1,581,018** final requests succeeded with zero errors.
Raw data: [before](../tests/benchmark-workers-2026-11-10-before.json) and
[after](../tests/benchmark-workers-2026-11-10-after.json).

This harness excludes driver/backend CPU and memory. CPU covers the child's
entire lifetime, including startup, TLS handshakes and shutdown; throughput is
timed after all handshakes complete. RSS is the OS process high-water mark.
Unlike `make compare`, there is no TCP stack, listener/accept workload, idle RSS
sample, or periodic reconnection: inherited connections have their request cap
raised for this fixture. The normal daemon retains its 1,000-request cap.
The tests share the host and are not pinned to cores. Do not compare these
absolute rates or RSS values with the TCP table, or assume a 10% TCP gain.

Verification passed: all four V test files, including worker admission/shutdown,
HTTP framing, normalized routes, TLS backpressure and certificate replacement.
The separate-process reactor also completed 1 MiB TLS responses with one and
two workers without errors.

To measure whether the TCP gap has closed on the user's host:

```sh
make compare COMPARE_ARGS='--output benchmark-results-optimized.json'
make compare COMPARE_ARGS='--vaddy-workers 2 --output benchmark-results-workers2.json'
```

Both commands rebuild Vaddy as needed and build Caddy and Raddy. `--vaddy-workers`
is saved in the report; Caddy and Raddy keep their default scheduler settings. The original TCP
baseline remains archived above until new comparable measurements are available.

## Executable sizes

The binaries present for this baseline are 826,320 bytes (807 KiB) for Vaddy and
54,161,794 bytes (51.65 MiB) for Caddy. Vaddy's shared OpenSSL and GC libraries are
additional. The optimized Vaddy build is 827,568 bytes (808 KiB). File size is
separate from the RSS measurements above.

## Vaddy socket-pair microbenchmark

Command: `make bench`, three separate runs. Each run sends 100,000 sequential
HTTP/1.1 keep-alive requests, with an asset rewrite and a 512-byte response,
through the actual Vaddy parser/proxy I/O code over anonymous socket pairs.
The test resets the 1,000-request connection counter to measure steady reuse.

| Run | Requests/s | Wall time | Process CPU time | CPU/request | CPU utilization | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 63,211 | 1.582 s | 2.030 s | 20.30 µs | 128.3% | 15.31 MiB |
| 2 | 65,445 | 1.528 s | 2.110 s | 21.10 µs | 138.1% | 15.30 MiB |
| 3 | 49,800 | 2.008 s | 3.818 s | 38.18 µs | 190.1% | 12.31 MiB |
| Median | **63,211** | **1.582 s** | **2.110 s** | **21.10 µs** | **138.1%** | **15.30 MiB** |

CPU time is user + system time from `getrusage`, sampled around the request
loop. 100% is one fully used CPU core; GC can use helper threads. RSS is the
process high-water mark. These measurements include the test's client/backend
I/O and assertions in the same process; RSS also includes earlier TLS and
certificate tests. The timed workload is cleartext HTTP, not HTTPS. This is not
standalone daemon memory, a real TCP benchmark, or a Caddy comparison. Run-to-run
CPU and throughput variance is substantial; no production capacity claim is
justified from these short samples.
