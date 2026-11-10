# Performance lessons from Vaddy

Recorded on 2026-11-10 to preserve the findings and decisions from implementing
and optimizing Vaddy. This document is a handoff for future work, with lessons
about V code, networking, TLS, threading, and measurement. It describes this
repository and the compiler actually used; it is not a claim about every V
release or every server workload.

The objective remains a small V reverse proxy compatible with the supplied
[Caddyfile](../Caddyfile), including HTTP on 80, HTTPS on 443, automatic certificate
management, asset rewrites, and response-header removal. Throughput improvements
must preserve the low CPU and memory costs and the protocol behavior.

Contents: [Results](#current-state-and-evidence) ·
[Metrics](#read-the-metrics-correctly) ·
[V allocations](#v-allocation-and-data-structure-lessons) ·
[Networking and TLS](#network-and-tls-event-loop-lessons) ·
[Threading](#threading-and-ownership-lessons) ·
[V/C and build pitfalls](#two-concrete-vc-and-build-pitfalls) ·
[Measurement](#measurement-and-profiling-lessons) ·
[Next steps](#reproduction-and-the-next-investigation) ·
[Code map](#code-and-evidence-map)

## Current state and evidence

The optimized implementation is built. It defaults to one event-loop worker;
`--workers N` enables up to 64, capped by the connection limit. Parsing, buffer
reuse, readiness handling, and routing were optimized. The HTTP/HTTPS defaults
and certificate-management behavior were retained.

The measurements used macOS 27.0.1 arm64, V `0.5.2 b7b4dd4`, Clang, Boehm GC,
OpenSSL 3, and Go 1.27.2 for Caddy and benchmark helpers. Production V flags are
`-prod -cc clang -gc boehm -d use_openssl`. Linux epoll support is present but
has not been validated by these macOS runs.

### Original TCP comparison

The user ran `make compare` outside the development sandbox. These are medians
of three ten-second runs, HTTP/1.1 over TLS 1.3, with a 512-byte backend response.

| Server | Clients | Requests/s | CPU usage | CPU/request | Mean latency | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Caddy | 1 | 5,631 | 103.0% | 182.93 µs | 0.177 ms | 52.4 MiB |
| Vaddy | 1 | 7,832 | 39.2% | 50.05 µs | 0.128 ms | 10.7 MiB |
| Caddy | 32 | 26,482 | 372.0% | 140.82 µs | 1.208 ms | 67.3 MiB |
| Vaddy | 32 | 20,914 | 98.4% | 47.00 µs | 1.530 ms | 12.7 MiB |

At 32 clients, Vaddy spent much less CPU per request but used roughly one core;
Caddy used about 3.72 cores. A busy single reactor is a plausible explanation
for the aggregate throughput gap. This was not an equal-core experiment, and
the utilization figures alone do not identify every bottleneck.

### Vaddy optimization results

Listening sockets were denied in the development sandbox, but anonymous Unix
socket pairs worked. A separate Go process drove clients and backends while a
child Vaddy process ran the actual reactors, TLS, HTTP parser, and proxy logic.
Three five-second samples used 32 clients and 512-byte TLS responses.

| Request path | Workers | Requests/s | Server CPU/request | Server peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Before optimization | 1 | 46,705 | 21.36 µs | 12.36 MiB |
| After optimization | 1 | 51,394 | 18.91 µs | 12.31 MiB |
| Before optimization | 2 | 45,798 | 36.95 µs | 14.63 MiB |
| After optimization | 2 | 54,719 | 26.97 µs | 14.61 MiB |

The before build already contained the optional worker pool. These comparisons
measure the subsequent request-path changes. One worker gained **10.0%**
throughput and used **11.5%** less CPU per request. Two workers gained **19.5%**
against their own earlier result. In the final build, two workers bought only
6.5% more throughput than one, for 42.6% more CPU per request and about 2.3 MiB
more peak RSS. That is why one worker remains the default.

All 1,581,018 requests in the final small-response runs succeeded. Separate
1 MiB TLS response runs also passed with one and two workers. The four V test
files passed, including framing, routing, streaming, worker admission/shutdown,
TLS backpressure, certificate replacement, and mock ACME.

These socket-pair numbers cannot be compared directly with the Caddy TCP rates.
We have not established that the optimized Vaddy closes the real TCP throughput
gap. The next decisive measurement is a fresh `make compare` on a host that
permits listeners. Public ACME deployment and Linux/BSD runtime verification
also remain separate from this performance work.

Full methodology and archived samples are in
[doc/BENCHMARKS.md](BENCHMARKS.md). Preserve those archives when rerunning
benchmarks; root-level output files are disposable.

## Read the metrics correctly

For each sample, with CPU time including user and system time:

```text
requests/s    = successful requests / elapsed wall seconds
CPU percent   = 100 * server CPU seconds / elapsed wall seconds
CPU µs/req    = 1,000,000 * server CPU seconds / successful requests
```

100% CPU means one fully used core, not the whole machine. Lower CPU/request is
better; higher requests/s is better. CPU/request measures resource consumption,
while latency includes waiting for the event loop, sockets, backend, and other
requests. They are not interchangeable.

For a saturated one-core path, `1,000,000 / CPU µs per request` is a useful rough
throughput check. The original 47 µs/request gives roughly 21,300 requests/s,
close to the observed 20,914. It is a sanity check, not a capacity guarantee.
For clients issuing one request at a time, concurrency divided by throughput
similarly approximates mean response time under steady load.

Compare percentages with an explicit denominator: Caddy being 26.6% faster than
Vaddy is equivalent to Vaddy delivering 21.0% fewer requests/s than Caddy. The
reported columns are medians calculated independently; recomputing ratios from
rounded median columns can differ from the original sample calculations.

Peak RSS, idle RSS, heap allocation rate, and executable size answer different
questions. A smaller binary does not prove lower resident memory, and unchanged
RSS does not prove that an allocation optimization did nothing. Less allocation
can reduce CPU and collection work without changing the process high-water mark.
The optimized Vaddy executable was 827,568 bytes; OpenSSL and GC shared libraries
are additional.

## V allocation and data-structure lessons

### Inspect the compiler and library implementation being used

Short V expressions can hide allocation, copying, or conversion. During this
work we inspected `vlib/builtin/string.v`, `vlib/builtin/array.v`, and
`vlib/strings/builder.c.v` in the installed compiler checkout. Ordinary string
substrings copied their contents, and `Builder.str()` copied accumulated bytes
into an owned string before clearing the builder. These details matter inside
a loop processing tens of thousands of requests per second.

Do not assume a substring is a borrowed view, an array assignment is a deep
copy, or a clear operation always preserves storage under every aliasing mode.
Check the relevant implementation and, when necessary, generated C. Recheck
these assumptions after compiler changes rather than generalizing from syntax.

### Scan bytes without manufacturing temporary arrays

The original token checks iterated over `s.bytes()` and repeatedly converted a
punctuation string to bytes for membership checks. Header parsing also split
whole messages into line arrays and split start lines into word arrays.

The replacements use indexed string-byte scans, explicit token-character
matching, and `index_after` with offsets into the original string. In particular,
`raw.index_after('\r\n', position)` avoids creating `raw[position..]` merely to
search it. Header names and trimmed values are extracted after boundaries have
been located; an intermediate copy of the whole header line is unnecessary.

This also requires preserving bounds checks and grammar. A colon found after
the current line terminator is not that line's header separator. The faster
parser still rejects malformed tokens, bad URI escapes, ambiguous framing,
duplicate Host/Content-Length fields, and length overflow. Removing validation
would change the workload and the server's correctness, not just its speed.

### Normalize once where the lifetime permits it

Each parsed `Field` stores its lowercase name as well as the original name.
Forwarding reuses that key instead of lowercasing every header a second time.
Header names have already passed ASCII token validation, so `to_lower_ascii()`
is appropriate there. The same shortcut is not automatically appropriate for
arbitrary URI paths or other text that can contain non-ASCII characters.

Configured route patterns are lowercased once during configuration parsing.
The common path avoids splitting, normalizing, and joining segments unless the
decoded path contains `/.` or `//`. Percent decoding and matching semantics
remain in place. Tests cover case differences, encoded separators, dot segments,
repeated slashes, exact matches, trailing slashes, and query preservation.

The general opportunity is to move immutable work from request lifetime to
configuration lifetime. Any cache of request-specific data needs a different
ownership and invalidation argument.

### Reuse connection-local storage and release stale references

`parse_message_reuse` accepts the previous header array owned by that connection.
It clears the previous entries and reuses capacity for the next message.
Resetting the surrounding `Message` must also reset framing, connection options,
close/upgrade flags, and other request state; reusing storage must not reuse
the previous request's semantics.

Reducing an array's length alone can leave old references in retained storage.
With a tracing collector, those references can keep objects reachable. The code
assigns `Field{}` to previously used entries before clearing the array. Otherwise
a large header followed by small requests could leave old strings in unused
capacity. Prefer typed clearing to blindly zeroing arbitrary V structures.

Reuse works because one reactor owns each connection. Do not generalize the
array reuse technique to data still referenced by another thread or operation.

### Build output in its final reusable buffer

The earlier header path created a builder, interpolated temporary strings,
converted the builder to a string, converted that string to bytes, then copied
the bytes into the connection's output queue.

`Buffer.data` now uses `strings.Builder`. `request_header` and `response_header`
write names, separators, and values directly into that buffer. This removes
intermediate representations while preserving buffer reuse between requests.
Small pieces are appended with `write_string`; there is no need to interpolate
an entire header just to append it immediately.

Keep the buffer cursor and compaction rules intact. Reusing the backing storage
does not make references into it stable across growth, compaction, or clearing.
We did not introduce borrowed parser strings or disable GC to get these gains.
The implementation still relies on GC for request metadata; `-gc none` would
require a separate lifetime/ownership redesign and validation.

### A bounded map can still do expensive work every request

The readiness table previously deleted a descriptor when its interest flags
became zero, then reinserted it when the next operation needed events. Profiling
showed repeated map backing-array expansion and compaction even with a stable
number of connections.

`Server.watch` now stores a zero value for disabled descriptors and removes the
entry only when the socket closes. Kernel event registration still changes as
needed. It also skips registration syscalls when flags are unchanged.

The lesson is to measure mutation churn, not just collection size. This is a
bounded cache tied to descriptor lifetime, not permission to retain closed
descriptors forever. Owners, watches, and client entries must be removed on
close so descriptor reuse cannot inherit stale application state.

## Network and TLS event-loop lessons

### Nonblocking does not mean free

The old pump attempted reads from both sockets on each event and could repeat
them after they had already returned EAGAIN. Such calls still cross into the
kernel or OpenSSL and consume CPU even when they transfer nothing.

The pump now tracks which input may be readable during that invocation. It
drains that input while making progress, and stops retrying it after EAGAIN.
It can still flush output immediately when processing creates new data. That
avoids adding an event-loop round trip solely to perform a write likely to fit.

Watch only useful readiness: writable sockets are frequently ready, so leaving
write interest enabled with no pending output can cause a busy loop. Check
nonblocking connect completion before treating a backend as connected. EOF,
temporary unavailability, and hard errors require different state transitions.

The implementation uses level-triggered epoll/kqueue behavior. Its bounded
pump work can return and rely on another readiness notification. Switching to
edge-triggered or one-shot operation would require redesigning the draining,
rearming, and backpressure rules; it is not a flag-only optimization.

### TLS has buffered state beyond kernel readiness

OpenSSL can hold records after the socket itself is no longer readable. The
pump also considers `SSL_has_pending` so buffered TLS input gets a chance to
progress. This predicate does not guarantee application bytes: incomplete or
non-application records may still lead to WANT_READ/WANT_WRITE. Stop retrying
when OpenSSL asks to wait rather than spinning on the pending predicate.

A TLS read can require writable readiness and a TLS write can require readable
readiness. Handshake, read, and write interests are tracked separately. A failed
`SSL_write` retry must preserve the data and length required by OpenSSL's retry
contract. Vaddy remembers the pending write length; the context enables
`SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER` to allow the same contents to move when
the queue is compacted. That mode does not allow changing the retry contents.

Plain HTTP benchmarks cannot validate these paths. The TLS tests exercise
handshake progression, write backpressure, and certificate-context replacement
while a connection remains alive.

### Bounded streaming is both a memory policy and a scheduling policy

Vaddy uses four lazy queues per connection with 32 KiB logical limits, a 16 KiB
I/O scratch buffer, and bounded pump iterations. It stops reading when the next
queue lacks room and resumes as output drains. Uploads and downloads stream;
the entire body is not buffered. WebSockets use the same flow-control machinery.

The queue limits are not a complete process memory bound. Capacity growth,
parsed metadata, thread stacks, TLS/GC allocations, and kernel socket buffers
add overhead. Four completely filled logical queues already represent 128 KiB
per connection, or 64 MiB across 512 clients before those other costs. Lazy
allocation explains why the small-response benchmark is much smaller.

Headers are limited to 16 KiB and 128 fields; chunk lines to 4 KiB and trailers
to 16 KiB. Keep these limits and the global connection cap when optimizing.
Increasing buffers or allowing unbounded queues can improve one benchmark at
the expense of slow-client behavior and memory use.

Bounded accept batches and pump iterations prevent one connection from owning
the event loop indefinitely. When capacity or descriptors are exhausted,
listener interests pause and retry later instead of spinning. The reactor
sleeps for readiness and performs periodic timeout/certificate checks.

### Reuse connections without hiding connection costs

Vaddy reuses a backend connection per client while the route and backend state
permit it. `TCP_NODELAY` is requested on TCP sockets. Name resolution occurs at
startup rather than in the request loop; upstream address changes currently
require restart. These are existing design choices, not separately measured
speedups from this optimization pass.

Keep-alive, fresh TLS handshakes, and connection churn are different workloads.
The daemon closes a client after 1,000 requests. The inherited-socket fixture
raises that cap because it cannot create replacement connections through a
listener. Never attribute that fixture behavior to the deployed server.

Certificate issuance, signing, and renewal run outside the request loop.
OpenSSL subprocesses serve those infrequent operations; proxied traffic uses
the OpenSSL library directly. Performance work must preserve the port-80
HTTP-01/redirect path and the port-443 TLS path, even when the benchmark uses
a supplied certificate and exercises neither issuance nor renewal.

## Threading and ownership lessons

### Partition connections, not individual requests

The main reactor accepts connections and assigns them round-robin to itself or
a worker. Each worker has its own event queue, client/owner/watch maps, and
connection buffers. A connection stays with that reactor for its lifetime.
Configuration and resolved backend addresses are shared as read-only data.

This keeps the common request path free of application-level cross-worker
queues and shared mutable connection maps. The pool shares atomic admission and
stop counters; those counters change on admission, close, or shutdown rather
than on every request. This does not imply that the allocator, GC, OpenSSL, or
kernel contains no shared synchronization.

The connection pointer crosses a channel once when ownership changes. The
receiver's `unsafe { received }` conversion permits mutable access under this
ownership convention; it is not synchronization or an automatic proof of
exclusive access. After publishing a connection, the sender must not continue
to manipulate it. Worker-visible heap objects must outlive the worker.

### Wakeups and admission need explicit invariants

A worker's channel is paired with a nonblocking socket-pair wakeup so its event
loop can sleep in the kernel. Publish the queued connection before sending the
wakeup. Drain the notifications and then the inbox. Notifications are prompts
to inspect the queue, not a one-byte-per-connection accounting mechanism.
If the wakeup socket is already full, an unread notification already exists;
the sender need not block just to add another wakeup byte.

The active-client counter includes queued connections, not just those already
registered in a reactor. Each inbox can hold the global connection limit, so
the sole acceptor cannot fill an inbox beyond its capacity while obeying that
limit. Every admitted connection carries a `counted` flag so cleanup decrements
the total exactly once. Initializing absent descriptors to `-1` and making close
idempotent avoids treating descriptor zero as an unused socket or closing twice.

The current check-then-increment admission scheme depends on there being one
acceptor. If future workers accept independently, an atomic load followed by an
atomic increment is not an atomic reservation; admission would need a different
protocol. Likewise, shrinking inboxes without changing dispatch can make the
acceptor block on channel send.

One inbox per worker also means queue-storage overhead grows with both worker
count and the configured limit. The global connection cap does not make every
component of memory use independent of worker count.

### Shutdown and certificate lifetime belong in the design

Shutdown stops admission, wakes sleeping workers, drains active requests within
the grace period, joins workers, and releases queued/owned connections. Cleanup
must also work after partial worker startup or a worker failure. The current
pool cleanup clears its bookkeeping so a second cleanup call is harmless.

Only the main reactor manages certificate-context publication and creates TLS
objects for accepted sockets. Each established TLS object is then used by its
owning reactor. Existing TLS objects retain their context when the main reactor
loads a replacement. Do not free worker-visible resources merely because the
acceptor has stopped or its own connection map is empty.

### More workers can make an efficient server less efficient

Before the request-path changes, two workers delivered about 45.8k requests/s
versus 46.7k for one, while CPU/request rose from 21.36 to 36.95 µs. Automatically
using every available core would have been an unsupported default.

Reducing allocations and copies helped the multiworker workload, but the final
two-worker result still scaled weakly. Possible explanations include allocator
or GC synchronization, scheduling, TLS/library overhead, and the shared host's
client/backend load. None was isolated sufficiently to declare it the cause.
The measurements do not establish that V threads or Boehm GC are intrinsically
unable to scale.

Connection count, worker count, backend parallelism, and available cores are
different controls. Round-robin assignment balances connection counts, not
request cost. Long-lived or unevenly busy connections can skew worker load.
Measure these effects before adding load balancing or work migration complexity.

## Two concrete V/C and build pitfalls

### Match C pointer element widths exactly

With the compiler used here, `sizeof(int)` is **8**, while `sizeof(i32)` is **4**.
The C socket-pair APIs write two C `int` values. Passing a V `[2]int` to that
output parameter produced invalid descriptor values because the element widths
and offsets did not match. Scalar argument conversions do not fix pointer or
array layouts.

The corrected adapter uses an explicit 32-bit output array:

```v
fn C.vaddy_wakeup_pair(&i32) int

mut fds := [2]i32{}
if C.vaddy_wakeup_pair(&fds[0]) != 0 {
    return error('cannot create wakeup sockets')
}
```

Convert each descriptor to the application's `int` representation after C has
written it. Apply the same discipline to structures, pointers, lengths, return
types, and signedness at ABI boundaries. Confirm the actual target/compiler
layout; do not assume V `int` universally matches C `int` or infer a permanent
language rule from this checkout.

### Never put required operations only inside assertions

An early optimized fixture put socket setup calls inside `assert`. In its
`-prod` build those assertions were removed, so the required calls did not run.
A benchmark can hang or measure different behavior because of its build mode.

Use ordinary execution and error handling for required effects:

```v
if C.vaddy_nonblock(fd) != 0 {
    return error('cannot make socket nonblocking')
}
```

Production fixtures must execute setup, requests, and validation independently
of assertions. The existing V test harness uses assertions with side effects,
so `make bench` deliberately uses Clang `-O3` without `-prod`. Do not switch that
target to `-prod` without first separating its effects from assertions. The
separate-process IPC fixture uses explicit checks and can use the production
flags.

## Measurement and profiling lessons

### Know what each harness measures

| Command | Execution model | Appropriate use | Important limit |
| --- | --- | --- | --- |
| `make bench` | Plain HTTP socket pairs; client, proxy and backend in one V test process | Fast request-path investigation | CPU/RSS include the test workload and earlier tests |
| `make bench-workers` | TLS socket pairs; Vaddy child and separate Go driver | Reactor, TLS and worker comparisons within Vaddy | No TCP listeners, accept workload, or periodic reconnections |
| `make compare` | Real loopback TCP/TLS; separate server, backend and load processes | Caddy/Vaddy comparison for this workload | Requires listeners and process metrics; all processes still share the host |

The IPC fixture substitutes connection setup, not the request-processing loop.
Directly calling `pump` in a unit test can miss readiness-registration bugs that
an actual reactor reveals. Keep both forms of test.

For the TCP comparison, CPU is sampled around measured load after warmup and
peak RSS is sampled every 100 ms. The IPC driver instead obtains child CPU and
peak RSS after exit. Its CPU includes startup, TLS handshakes, and shutdown,
although throughput timing begins only after all handshakes finish. Its RSS is
an OS high-water mark. The driver accounts for platform-specific `ru_maxrss`
units. These definitions must accompany the numbers.

Short idle observations returning 0.0% CPU mean no time was resolved at the
sampler's precision. They do not prove that the server performs no idle work.
Per-run mean latency is not p95/p99 latency, and a median of those means is not
a request-latency percentile.

### Use profiling to choose work, then time an uninstrumented build

V function profiling exposed repeated string splitting, token validation,
header construction, and map maintenance in the request path. It also changed
the observed throughput substantially. Inclusive timings overlap between caller
and callee; adding them double-counts work. Instrumentation disproportionately
affects very small, frequently called functions.

Use call counts and hot paths to formulate a change. Verify its effect with the
normal optimized executable. Do not rank implementations by instrumented
requests/s or treat a V function profile as a complete profile of C/OpenSSL,
kernel time, allocation contention, or scheduling.

The first readiness-only experiment raised the one-worker median from about
46.7k to 51.2k requests/s. Later parser, map/path, and header-output experiments
overlapped in one-worker throughput, while two-worker results improved more.
An exploratory two-worker header-output run reached a 57.3k median; the final
full build measured 54.7k. The final recorded result is the one to report, not
the highest intermediate number. Individual contributions were not isolated
in a complete controlled experiment, so their percentages cannot be summed.

### Preserve a comparable workload and enough evidence

Match TLS version, certificate type, HTTP version, payload, route, rewriting,
header filtering, concurrency, keep-alive policy, duration, and warmup. The
current comparison uses a supplied ECDSA P-256 certificate; self-signed
verification is disabled only in the benchmark client. This says nothing about
public ACME issuance cost or production certificate validation.

Validate status, body length, rewritten backend path, header removal, and error
counts. A faster failing request path is not a performance improvement. For
new streaming workloads, also verify payload integrity, not just transfer rate.

Use multiple runs, alternate server/worker order, preserve raw JSON, and report
medians and ranges. Avoid running builds, tests, or other benchmarks concurrently
with timed load. Backend/load-generator saturation, host contention, scheduling,
and thermal changes can obscure server improvements even when their CPU is
excluded from the reported server CPU.

Three short runs provide a useful development signal, not a statistical proof
or production sizing study. For the next comparison, record source revisions or
hashes, compiler/library versions, hardware/core availability, and binary/build
flags alongside the workload. The current raw JSON does not capture all of that
metadata; some provenance is recorded in the benchmark document.

## Reproduction and the next investigation

Run from the repository root. `make` selects the Homebrew OpenSSL 3 pkg-config
directory when available. Direct Python harness invocations need an equivalent
environment if the default pkg-config entry selects another OpenSSL version.

```sh
make
make test
./vaddy validate --config ./Caddyfile

# On a host that permits loopback listeners:
make integration
make compare COMPARE_ARGS='--output benchmark-results-optimized.json'
make compare COMPARE_ARGS='--vaddy-workers 2 --output benchmark-results-workers2.json'

# Inside the listener-restricted development environment:
GOCACHE=/tmp/vaddy-go-build make bench-workers

# Optional focused runs; preserve the build's OpenSSL pkg-config environment:
python3 tests/ipc_bench.py --workers 1 --runs 1 --seconds 2 \
    --profile /tmp/vaddy-profile.txt --output /tmp/vaddy-profile-results.json
python3 tests/ipc_bench.py --workers 1,2 --clients 4 --size 1048576 \
    --runs 1 --seconds 2 --output /tmp/vaddy-large-results.json
```

The temporary Go cache avoids writing to a protected default cache. It does not
grant network or listener access. Use one worker and one run for a function
profile so multiple workers/processes do not contend for or overwrite its file.

Next steps, in order of usefulness:

1. Rerun real TCP/TLS comparison with the current one- and two-worker builds.
   The original Caddy comparison predates the optimizations. There is no verified
   claim yet that current Vaddy outruns Caddy at 32 clients.
2. Vary concurrency, payload size, upload/download direction, TLS versus plain
   HTTP, connection churn, and slow readers/writers. Add latency percentiles for
   tail behavior. Compare both equal CPU budgets and unrestricted throughput.
3. On a host with profiling support, distinguish syscall cost, allocation/GC
   cost, TLS cost, scheduling, and driver/backend limits. Test the proposed
   explanation before changing the threading design or allocator.
4. Run prolonged keep-alive/churn tests and inspect retained memory after load.
   A short peak-RSS measurement cannot establish long-term memory stability.
5. Exercise Linux epoll and other supported platforms with the same correctness
   and load tests; a working kqueue run does not validate another event backend.

Possible later experiments include batched event-registration updates, different
TLS buffer retention, or reduced parser copying. These are unmeasured ideas.
Borrowed strings would need explicit buffer-lifetime guarantees; changing TLS
buffer retention trades memory against allocation work; event batching must
handle close/reuse and error ordering. None should replace the proven path merely
because it sounds faster.

## Code and evidence map

| File | Relevant responsibilities |
| --- | --- |
| [src/http.v](../src/http.v) | Header parsing, framing, token scans, reusable output buffers |
| [src/config.v](../src/config.v) | Configuration-time normalization, path matching and rewriting |
| [src/server.v](../src/server.v) | Nonblocking pump, backpressure, watches, timeouts, certificate reload |
| [src/workers.v](../src/workers.v) | Connection ownership, admission accounting, wakeups and shutdown |
| [src/platform.h](../src/platform.h) | Small POSIX/OpenSSL adapters; epoll/kqueue implementation |
| [src/platform.c.v](../src/platform.c.v) | V declarations for the C boundary |
| [src/acme.v](../src/acme.v) | Certificate work outside the request loop |
| [tests/ipc_bench.py](../tests/ipc_bench.py) | Reproducible builds and worker/profile experiments |
| [tests/ipc_server.v](../tests/ipc_server.v) | Inherited sockets entering production reactors |
| [tests/ipc_driver.go](../tests/ipc_driver.go) | Separate client/backend driver and child resource accounting |
| [tests/compare.py](../tests/compare.py) | Real TCP comparison orchestration and CPU/RSS sampling |
| [tests/bench_driver.go](../tests/bench_driver.go) | TCP load generator and backend |
| [doc/BENCHMARKS.md](BENCHMARKS.md) | Measured results, methodology and archived JSON links |
