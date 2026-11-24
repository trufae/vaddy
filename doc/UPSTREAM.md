# Upstream map: what we reimplemented, and what V/vlib should own

Vaddy is a streaming reverse proxy: ~7.3k lines of V in `src/`, plus
~1.4k lines of C/C++ in headers. A large part of that C is *not* application
logic — it is a replacement for things a server language should provide.

This file is the map. For each workaround: what we do, why, what vlib has
today, why that isn't enough, and what the upstream fix should be.

**Prefer vlib.** Use upstream APIs when they cover the required behavior and
contribute missing functionality there. Measure request-path replacements with
`make bench` and `make compare` before removing performance-sensitive local code.

**V from git only.** CI builds the revision in `ci/toolchain.env`.
The inventory below was recorded against `trufae/v` at `b7b4dd4`; recheck gaps
against the current pin before starting upstream work. Released V toolchains
are not supported; do not add release fallbacks.

Legend: **P0** = perf blocker, keep local. **P1** = real vlib gap, upstream PR
worth doing. **P2** = ergonomics/cleanup.

---

## 0. The map at a glance

| # | What we wrote | Where | Closest thing in vlib today | Verdict |
|---|---|---|---|---|
| 1 | epoll/kqueue/IOCP reactor + wakeup pairs | `platform_posix.h`, `platform_windows.h` | `vlib/picoev` (HTTP-shaped), `vlib/fasthttp` (own loops, no TLS) | upstream: a real reactor module |
| 2 | OpenSSL non-blocking adapter + ALPN | `platform.h` | `net.http` `-d use_openssl` (blocking, thread per conn) | upstream: `ssl` session API |
| 3 | HTTP/2 over nghttp2, multiplexed, streaming | `http2.h`, `http2.c.v`, `http2.v` | `net/http/h2_server.v` **serial, 1 stream, 8 MiB buffered** | upstream: concurrent reactor h2 |
| 4 | Streaming gzip/zstd encoder | `encode.h`, `encode.c.v` | `compress.gzip` (pure V, one-shot), `compress.zstd` (C, one-shot API) | upstream: streaming encoder |
| 5 | gzip a file for log rotation | `log/writer.h` | nothing | falls out of #4 |
| 6 | `fstat` on the open fd | `files.h` | `os.Stat` stats the path, `os` has no `fstat` | upstream: `os.fstat` |
| 7 | `flock`, atomic `rename`, signals, umask | `platform.h` | `os.rename` exists; no locking, no signal API | upstream: `os.lock_file` etc. |
| 8 | RE2 (C++) regex | `regex/regex.cc`, `regex/regex.c.v` | `regex` (PCRE-syntax, buggy), `regex.pcre` (fast VM, no lookaround, replace = first match, `$1` only) | upstream: `regex.pcre` + Go-style replace |
| 9 | `Buffer` with read cursor + storage swap | `http.v` | `strings.Builder` (no cursor, `str()` copies) | upstream: builder cursor/swap |
| 10 | HTTP/1 incremental parser + framing | `http.v` | nothing resumable; `net/http/chunked.decode` is whole-buffer | keep ours (app-level), note API |
| 11 | `[]Field` instead of `map[string][]string` | `http.v` | `http.Header` is a map | keep (ordering + case) |
| 12 | token/control-char helpers, no `bytes()` | `http.v` | none; `string.bytes()` **copies** in the inventory baseline | upstream: borrowed `bytes()` |
| 13 | duration parser | `log/writer.v` | `time.parse_duration` exists (vlang/v #29956) | **done**: only Caddy's `d` rewrite stays |
| 14 | MIME perfect-hash table | `mime/mime.v`, `mime/data.v` | pinned `mime.get_mime_type` builds maps; local MIME branch has static perfect hashes | adopt upstream after mapping parity checks |
| 15 | multi-range file bodies, chunked pump | `files.v` | `fasthttp` sendfile (whole file only) | keep ours |
| 16 | JSON log records via encode→decode→encode | `log/format.v` | `json2` has no ordered/dynamic object writer | upstream: `json2` encoder API |
| 17 | reactor wakeup for worker channels | `workers.v` | no chan-with-fd | upstream: fd-backed chan |
| 18 | atomic counters | `sync.stdatomic` | fine | — |

---

## 1. C shims we never wanted to write (P0 block)

### 1.1 Event loop — `src/platform_posix.h`, `src/platform_windows.h`
We wrap epoll / kqueue / IOCP ourselves:
`vaddy_queue`, `vaddy_watch(q, fd, old_flags, new_flags)`, `vaddy_wait(q, &events, n, timeout_ms)`,
`vaddy_wakeup_pair`, `vaddy_notify`, `vaddy_nonblock`, `vaddy_again`,
`vaddy_accept`, `vaddy_recv`, `vaddy_send`, `vaddy_peer_port`, `vaddy_close`.

**Why**: one thread must own N connections, both client and upstream fds, and
change interest on the fly. Signals (SIGTERM/SIGINT/SIGHUP), `flock`, atomic
`rename`, `fstat` and the peer address all landed here because the reactor code
needed them.

**What vlib has**: `vlib/picoev` is the right shape (per-fd `Target`, per-fd
callback, kqueue/epoll backends, timeouts) but is unusable as a library today:
- `loop_once()` is **private**; the only driver is `serve()`, which spawns a
  date-string goroutine and loops forever,
- the loop is HTTP-shaped (`cb fn (voidptr, picohttpparser.Request, mut picohttpparser.Response)`),
  and `raw_cb` is a single global callback, not per-fd,
- one global `user_data` (we need per-connection state; we'd have to look up
  `clients[fd]` inside every callback),
- `max_fds = 1024` fixed, `file_descriptors [4096]&Target`, and
  `timeouts map[int]i64` touched per add/delete — a map op per fd event.

`vlib/fasthttp` is closer in spirit (epoll/kqueue/IOCP, per-worker
`SO_REUSEPORT` listener, zero-alloc request path, `sendfile`, graceful shutdown,
takeover) but it owns HTTP/1 request parsing and has **no TLS support anywhere**
(no ssl/tls reference in any of its files). We proxy TLS and HTTP/2, so we can't
sit on it.

**Upstream fix**: a lean `event` module (or a public picoev core):
`queue() !int`, `watch(fd, events) !`, `unwatch(fd)`, `wait(events []Event, timeout_ms) int`,
`wakeup_pair() (int, int)`, `notify(fd)`, `again() bool`. Constraints from us:
`wait` must fill a caller-owned array (no allocation), `Event` must be a plain
`{fd int, flags int}` struct, `watch` must be idempotent when flags are
unchanged (that's why we keep disabled fds registered until close — see the
comment in `server.v`), and per-fd user data must be possible without a map.

That's a contained change to `picoev`, and it unblocks every V server that isn't
an HTTP/1 static file server.

### 1.2 TLS — `src/platform.h` (OpenSSL)
`vaddy_tls_context/new/read/write/handshake/error/pending/has_pending/free`,
`vaddy_upstream_context/upstream_tls/upstream_handshake`, `vaddy_tls_is_h2`,
`vaddy_tls_details` (version, cipher id, resumed, SNI, ALPN), and the ALPN select
callback preferring `h2`.

**Why**: vlib's `net.http` TLS (`-d use_openssl`) is a *server over V's `net`*:
blocking reads, thread per connection. There is no API that hands you a session
object you drive from a non-blocking fd with your own event loop. Client side is
worse: we need `SSL_set1_host`, IP SAN handling via `a2i_IPADDRESS`, SNI, and a
strict `http/1.1`-only ALPN for upstreams. We also deliberately set
`SSL_MODE_RELEASE_BUFFERS` and `SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER`; a wrapper
has to expose those.

**Upstream fix**: `ssl` module with
`Context{ cert, key, alpn, min_version, modes, verify }` and
`Session{ handshake() int, read(mut []u8) int, write([]u8) int, wants() Want,
pending() int, alpn() string, error() SSLResult, servername() string }`,
server and client. Non-blocking, allocation-free, caller-provided buffers.
Note: on the hot path we cannot take a `!` result unless it is error-code-free
(V errors allocate today) — expose the raw int as well.

### 1.3 HTTP/2 — `src/http2.h` + `src/http2.c.v` + `src/http2.v`
259 lines of C over nghttp2 exposing a *stream* struct into V
(`&C.vaddy_h2_stream` stored on our `Connection`), plus
`h2_receive / h2_flush / h2_wire / h2_wire_skip / h2_take / h2_push /
h2_response / h2_end / h2_reset / h2_remove / h2_drain / h2_wants_write /
h2_finished`, i.e. byte-in → stream events → exact wire bytes out, with flow
control windows.

**Why**: `vlib/net/http/h2_server.v` says it outright in its header comment:
*"intentionally serial: SETTINGS_MAX_CONCURRENT_STREAMS is advertised as 1 …
Concurrent stream handling and background writers are a planned follow-up"*,
and it buffers up to 8 MiB of request body in memory. `h2_conn.v` is a *client*.
`h2_frame.v` and `h2_hpack.v` are good pure-V building blocks, but there is no
concurrent server driver. We need many concurrent streams per connection, bodies
streamed (never buffered whole), interleaved with upstream writes, all on one
worker thread.

**Upstream fix**: finish `h2_server.v` — concurrent streams, streaming bodies,
"feed bytes / take events / take wire bytes" API, no per-frame allocation, and
an explicit non-blocking contract. Then `http2.h` dies. Biggest piece of C in
the tree and the highest-value contribution, but also the biggest.

**Side effect of the current design**: `&C.vaddy_h2_stream` on `Connection` is
why `server.v` is hard to unit test. Fixing #1.3 also fixes that.

### 1.4 Streaming compression — `src/encode.h`, `src/encode.c.v`
`vaddy_encoder_new(kind, level)`, `_step(enc, in, inlen, out, cap, finish)`, `_free`.
gzip/deflate via zlib, zstd via libzstd, one call per response slice.

**Why**: `compress.gzip` is a pure-V one-shot `compress([]u8) []u8` — new array
per call, far too slow in a per-request path. `compress.zstd` exposes
`new_cctx`/`compress_stream2` (real streaming) but the shape is "fill an
`OutBuffer`, feed an `InBuffer`, check a return code", not "here is an output
slice, tell me how many bytes you used". Proxy encoding needs `Z_SYNC_FLUSH` at
chunk/SSE boundaries and a hard bound on the output.

**Upstream fix**: `Encoder` with `feed(input []u8, output []u8, flush Flush)
(consumed int, written int)` for both `compress.gzip` and `compress.zstd`, plus
`finish()`. Zero allocation per call, no `Buffer` growth. gzip is P0 (pure V is
not competitive); zstd is mostly an API-shape change.

### 1.5 `vaddy_gzip_file` — `src/log/writer.h`
20 lines: open file → `gzwrite` loop → `gzclose`, for rotated log backups.
**Why**: same as #1.4 — nothing to call with bounded memory.
**Verdict**: P2, deleted for free once #1.4 exists.

### 1.6 `vaddy_file_info` — `src/files.h`
`fstat(fd)` (POSIX) / `GetFileInformationByHandle` (Windows) → size + ns mtime.

**Why**: we must describe the *inode we already opened*, not the path: static
files are replaced atomically underneath a request, so `os.Stat(path)` is a
TOCTOU bug. `os` exposes `os.File.fd` but has no `fstat`, `Stat` has no
nanosecond mtime field, and Windows needs the handle-based call. We also need
`S_ISREG` / `FILE_ATTRIBUTE_DIRECTORY` rejection here.

**Upstream fix**: `os.fstat(file os.File) !Stat` with `mtime_ns i64`, and
`os.is_regular(Stat)`. P1, small and uncontroversial.

### 1.7 Locking, atomic rename, signals, umask — `platform.h`, `platform_posix.h`
`vaddy_lock/unlock` (flock / LockFileEx), `vaddy_replace` (rename),
`vaddy_signals`/`vaddy_stopped`/`vaddy_take_reload` (async-signal-safe flags),
`vaddy_private_files` (umask).

**Why**: `os.rename` exists (fine), but there is no file locking in vlib (we need
single-instance and reload-mutex semantics that survive a crash) and no signal
API at all. `vaddy_private_files` exists because `os.chmod` on a directory does
not stop the next file from being created 0644 while a certificate is written.

**Upstream fix**: `os.lock_file(path) !Lock` + `Lock.unlock()`,
`os.signals.wait() []Signal` driven by a dedicated thread (or a callback API
documented as async-safe), and `os.set_umask(mode)`. P1 for locking, P2 rest.

---

## 2. Regex from C++ — why, and how to kill it

**What we do**: `src/regex/regex.cc` (C++17, `#pkgconfig re2`, compiled to
`.build/regex.o`, linked with `#flag`). Two entry points:
`vaddy_regex_valid(pattern)` and `vaddy_regex_replace(pattern, repl, input, out, cap)`.
The replace implements *Go `regexp`* semantics, because that is what Caddy uses:
`$1`, `${name}`, `$name`, `$$`, unmatched groups → empty, zero-width matches
advance by rune, output capped (returns `-2`, never overflows the header limit).

**Why it was done, in order of weight**:
1. **Semantics**: Caddy's `header` and `log format filter` regexes are Go
   `regexp` (RE2). `header @m X-Foo (a)(b) $2-${1}` must behave like Go or we are
   not compatible. vlib has no Go-style replacement.
2. **Time safety**: a pattern from a config file runs per request. RE2 is
   linear-time with `max_mem = 8 MB`. A backtracking engine on `(a+)+$` is a DoS.
3. **Correctness**: old `vlib/regex` is PCRE *syntax* only — `group_max = 8`,
   max nesting 3, no lookaround.
4. **Speed**: unanchored search on the old engine is slow.

**What vlib has**: `vlib/regex/pcre` (regex2 0.9.6)
is a genuinely good VM engine — zero-allocation search, ASCII bitmap classes,
Boyer-Moore prefix skip, named groups, `(?i)(?m)(?s)`. What it lacks for us:
- **no lookaround** (`(?<=a)b`, `(?!x)`) — we test that such a pattern must be
  *rejected*, not silently mis-matched,
- `replace()` replaces the **first** match only, and only supports `$1`..`$9`
  (no `${name}`, no `$name`, no `$$`),
- no "compile and return a structured error" suitable for config validation,
- `find_all` returns `[]Match` with `groups []string` → allocation per match.

**Priority**: P0 to keep RE2 *now* (correctness + DoS resistance + Go parity).
P1 to get out of it.

**Upstream path, cheapest first**:
1. `regex.pcre`: add `replace_all(text, repl)` with Go substitution
   (`$name`, `${name}`, `$$`, unmatched → empty) and a clear
   `lookaround_unsupported` compile error. `src/regex/regex_test.v` already encodes
   the exact expectations (7 assertions) — a ready-made upstream test file.
2. `regex.pcre`: expose compile errors properly, and add a `Machine`-reuse /
   `find_all_into(mut []Match)` path so callers can stay allocation-free.
3. Honest alternative: add `vlib/regex/re2` — a vendored, statically built RE2
   binding, so the engine Caddy actually uses is available in V with no
   pkg-config and no user-supplied C++ flags.
4. Long term: `regex.replace_all_bounded(pattern, repl, input, max_out) !string`
   in vlib. Our `expand()` in `regex.cc` is ~50 lines of exactly that logic and
   ports to V directly.

**Cost of not fixing**: a C++ compiler becomes a build dependency of a pure-V
project; `make` needs a `.build/regex.o` prerequisite; Alpine/musl must link
`libstdc++`; Windows CI needs RE2 built.

---

## 3. V/vlib things reimplemented locally (no C involved)

### 3.1 `Buffer` — `src/http.v`
`struct Buffer { data strings.Builder; pos int }` adding: a movable read window
so `bytes()` is a zero-copy view, `room()`, `skip()`, `clear()`, and
`transfer_to()` which **swaps** storage between two queues so a drained
destination steals the pending queue instead of copying it.

**Why**: `strings.Builder` has no read cursor, and `Builder.str()` allocates +
copies accumulated bytes before clearing (documented in `doc/PERFLEARN.md`).
`drain_builder(mut other, cap)` does exist (since 2021, `@[manualfree]`): it
appends `other` into `b`, then `free()`s `other` and re-creates it with
`new_builder(cap)`. That is a *drain*, not a *swap* — the source loses its
capacity and `cap` has to be guessed, and `b << *other` is a full copy anyway.
For `transfer_to` we need to exchange ownership when the destination is empty
and we keep our own buffer when it isn't, so we can't use it. See
`Buffer.transfer_to` in `src/http.v`.

**Upstream fix** in `strings`: `Builder.read_pos`, `bytes() []u8` view,
`room() int`, `skip(n)`, `swap(mut other Builder)`, and a documented
`clear_keep_capacity()`. P0 value: an allocation + memcpy saved per request
*and* per response, for every V server, not just us.

### 3.2 HTTP/1 parser + framing — `src/http.v`
`parse_message_reuse(raw, request, head, fields)` and `Framing.consume(data) !int`:
indexed byte scans, `index_after` instead of substrings, a chunked state machine
that never buffers a whole chunk, trailers with their own size budget, request
target/percent-escape validation, CL/TE conflict rules, 128-header and 16 KiB caps.

**Why**: no resumable server-side HTTP/1 parser exists in vlib.
`net/http/chunked/dechunk.v` is `decode(text string) !string` — whole buffer.
`net.http.Server` is thread-per-connection and has no streaming / write
backpressure control (no chunked writes, no "hand me the socket" mode).

**Verdict**: legitimately ours. Two things worth upstreaming anyway:
(a) an incremental `http.Parser` API shape, (b) the `parse_message_reuse`
contract — "caller owns the `[]Field` array and gets it back with capacity
intact" — which is the actual perf trick, and only makes sense if `[]Field`
exists upstream.

### 3.3 `[]Field` instead of `map[string][]string`
`Field{name, lower, value}` (`http.v`) + `field_value(fields, name)` (living in
`encode.v`, a mild layering smell).

**Why**: V maps allocate buckets on insert; we need original order *and* original
case for forwarding, plus a precomputed lowercase key. `http.Header` is a map and
lowercases keys.

**Upstream**: P2. If a slice-backed `http.Header` ever exists, take it; don't
push for it — ordering/case semantics are ours by design.

### 3.4 Token / control-char / digit helpers — `src/http.v`
`is_token`, `all_digits`, `invalid_controls(s, allow_tab)`.

**Why**: `s.bytes()` **copies** in the inventory baseline (`vlib/builtin/string.v` allocates a
`[]u8` and `vmemcpy`s). So every "does this string contain only token chars"
one-liner costs an allocation. We index the string directly instead.

**Upstream fix** could expose a read-only byte view or add `string.byte_at(i)`.
Either would let validation helpers scan the bytes without allocating. P0.

### 3.5 `log.parse_duration` — `src/log/writer.v` — **resolved**
`log.parse_duration` uses `time.parse_duration` from vlib. It only converts Caddy's
`d` unit to hours (including compound forms such as `1d30m`) and rejects
negative durations for log rotation. No local duration parser is needed.

### 3.6 MIME table — `src/mime/`
Generated CHD perfect hash with static displacement/slot arrays, packed extension
bytes and deduplicated media types. `mime.lookup` hashes up to three eight-byte
windows and verifies the complete key without allocating or building runtime maps.
The `.vsh` generator verifies all 1,203 frozen mappings before writing the table.

Regenerate with `v -gc none run tools/generate_mime.vsh .tools/v/vlib/net/http/mime/db.v`.
The source hash and attribution remain in the generated file and
[third-party notices](THIRD_PARTY.md). Lookup keeps the exact lowercase-extension
contract; file-serving normalization, JavaScript overrides and unknown-file handling
stay at the HTTP adapter.

The implementation follows the local V MIME branch's word-window perfect hash.
Its newer database differs from our frozen mappings, so adopting the upstream module
still requires data-parity checks. Local lookup and static-file benchmarks are kept
in `.build/mime-bench/`; lookup speed alone is not a server-throughput result.

### 3.7 Log rotation — `src/log/writer.v`
Size/interval rotation, timestamped backups with collision probing, prune by
count/age, reopen-per-write so Windows renames don't fail.

**Why**: nothing in vlib. Mostly genuine app logic; the only workaround bits are
`C.vaddy_gzip_file` (#1.5) and the reopen dance (a Windows `os.rename` detail).
P2.

### 3.8 Multi-range bodies — `src/files.v` (`FileOutput`, `pump_file`)
Multipart/byterange bodies, prefix/suffix, deferred `Content-Range`, streaming
from the open file into the output queue with backpressure.

**Why**: app logic. Note for upstream: `fasthttp` has zero-copy `sendfile` for a
whole file but can't serve our multi-range/multipart case, and no
`os.File.read_into(mut []u8)` helper exists. P2.

### 3.9 JSON access records — `log.Config.encode` (`src/log/format.v`)
Encodes `log.Record` → JSON string, **decodes it back to
`map[string]json2.Any`**, merges format fields and extras, then re-encodes.
Two full round trips per log line.

**Why**: `x.json2` has no "write an object with runtime-chosen keys in a chosen
order" API.

**Upstream fix**: a `json2.Encoder` streaming API —
`begin_object() / field(name, value) / end_object()` — or
`json2.encode_ordered(map, keys []string)`. P1. Also the ugliest code in the
tree today.

### 3.10 Worker wakeup — `src/workers.v`
`chan &Connection{cap: max_connections}` per worker + a socketpair
(`C.vaddy_wakeup_pair`) so a worker's reactor can be woken by a `chan` send.

**Why**: a V `chan` has no fd. `select { received := <-inbox }` inside a reactor
needs something epoll can see, otherwise the worker either busy-loops or blocks.

**Upstream fix**: a channel with an associated eventfd
(`sync.new_notifiable_chan()`, exposing `.fd()`), or a documented "queue + fd"
primitive. P1 — every actor-with-IO design in V hits this.

### 3.11 `stdatomic` counters — `workers.v`, `server.v`
`stdatomic.add_i64/load_i64/sub_i64` around `pool.active` / `pool.stopping`.
Fine as-is; only goes away if #1.1 brings an actor model. No action.

---

## 4. Deliberate duplication we should *keep*

Document these as intentional so nobody "cleans them up" later:

- HTTP/1 parser and framing (`http.v`) — different lifetime model than vlib's.
- `HeaderEdit` ordering semantics (`headers.v`) — Caddy's group-by-action,
  deferred/proxy phases, reverse unwind. Must stay app-level.
- `normalized_path` + matcher evaluation (`config.v`, `headers.v`) — Caddy
  semantics by definition.
- MIME const array even after #3.6 lands — unless upstream uses exactly the same
  representation, ours is measurably cheaper.
- `Buffer` even if `strings.Builder` gains a cursor — we still need
  `transfer_to` swap semantics until #3.1 lands fully.

---

## 5. Proposed module layout (kills the flat `src/`)

V requires one module per directory and **forbids import cycles**. Logging,
Caddyfile syntax and RE2 now have separate modules; HTTP and server code
still share `module main`. Remaining layering, bottom-up:

```
src/main.v                    module main     cli(), main(), wiring
src/core/                     module core     imports no vaddy module
    buffer.v                  Buffer (from http.v)
    platform.c.v + *.h        reactor/OS shims (from platform.*)
    validate.v                is_token, invalid_controls, all_digits
src/httpio/                   module httpio   imports core
    message.v, parse.v, framing.v       (http.v minus Buffer)
src/regex/                    module regex    imports no vaddy module
    regex.c.v, regex.cc, regex.h
src/tls/                      module tls      imports core
    session.c.v               OpenSSL half of platform.h
src/h2/                       module h2       imports core
    conn.c.v, conn.h, streams.v, glue.v (src/http2.*)
src/compress/                 module compress imports core
    encoder.c.v, encoder.h              (src/encode.c.v + encode.h)
src/mime/                     module mime       mime.v, data.v
src/caddyfile/                module caddyfile parser.v (Directive/tokenizer/parser)
src/log/                      module log       config.v, access.v, format.v, writer.*
src/config/                   module config   imports core, caddyfile, log, regex, mime
    config.v    (Route/Site/Config)
    headers.v   (HeaderEdit + expansion)
    encode.v, redirect.v, log_rules.v, files_config.v
    upstream.v
src/files/                    module files    imports core, httpio, config
    serve.v, ranges.v, browse.v         (files.v, split by concern)
src/server/                   module server   imports everything above
    connection.v, reactor.v (serve_events/accept/tick), workers.v,
    respond.v, forward.v, h2_streams.v, apply_headers.v,
    access_log.v (HTTP adapters), reload.v, acme.v
```

Caveats to resolve *before* starting:

- `Field` is used at parse time (`config/headers`) and request time (`server`).
  Put `Field` + `Buffer` in `core` so both can use them without a cycle.
- `HeaderValues`, `header_edit_matches`, `placeholder_value` are used by `config`
  (validation) and `server` (application). Put the *apply* half
  (`apply_header_group`, `expand_placeholders`, `buffer_header_fields`,
  `write_header_fields`) in `httpio`, since it only needs `Field`/`Buffer`.
- `EncodeConfig`/`EncodedOutput` hold `&C.vaddy_encoder` and `Buffer`, and are
  read by `server`. Keep the plain config struct in `config`; move the streaming
  state machine (`prepare_output`, the encode step) into `server`.
- `regex.valid` and `regex.replace` are shared by headers and log filters
  through the existing leaf `regex` module.
- `module main` must stay in the root; `v src -o vaddy` still works. Only the
  `Makefile`/CI patterns change (`src/*.v` → `src`).
- `core` will absorb most `C.` declarations. That is fine — it is the platform
  layer, and it is the module that shrinks as upstream work lands.
- `src/*.h` moves with its `.c.v` sibling; `@VMODROOT/src/x.h` include paths
  must be updated in the same commit or the build breaks.

Migration order (each step compiles and passes `make test`):

1. `core`: `Buffer`, `mono_ms`, `platform.c.v`, validate helpers. Biggest import
   ripple — HTTP and server code still share `module main`.
2. `httpio`: `http.v` minus `Buffer`.
3. `regex`: already extracted, with validation and bounded replacement.
4. `tls`, `h2`, `compress`: pure C-binding files, mechanical.
5. `config`: syntax already extracted; split model / matchers / directive parsers.
6. `server`: split reactor / connection / forwarding / logging / acme.
7. `files`: split out of the server once `Connection` lives in its own module.

Keep `make test` green at every step; never combine 1–2 with a perf change.

---

## 6. Upstream PR order (value per effort)

1. **Static `mime.lookup` with matching data** (§3.6) — deletes 1211 lines + a generator.
2. **`regex.pcre.replace_all` with Go substitution + explicit lookaround
   rejection** (§2) — makes `regex.cc` removable; our test file is the spec.
3. **`os.fstat`** with nanosecond mtime (§1.6).
4. **borrowed `string.bytes()`** (§3.4) and **`strings.Builder` read cursor +
   swap** (§3.1) — language-level; helps every V program, not just us.
5. **`json2` ordered/dynamic object encoder** (§3.9) — kills a double round trip.
6. ~~`time.parse_duration`~~ — already upstream (#29956); §3.5 resolved.
7. **streaming `compress.gzip` / `compress.zstd` encoder** (§1.4, §1.5).
8. **`os.lock_file`**, `os.signals`, `os.set_umask` (§1.7).
9. **`event` reactor module** — make `picoev`'s core public and
   non-HTTP-specific (§1.1) — plus **non-blocking `ssl` sessions** (§1.2).
10. **concurrent, streaming `net.http.h2_server`** (§1.3) — biggest, last.

Items 1–5 are small, independently mergeable, and each deletes real code here.
Items 9–10 are the ones that would let a V-native server stop writing C at all.

---

## 7. Checklist

- [ ] §3.6 adopt upstream `mime.lookup` after mapping parity checks; remove custom tables
- [ ] §2 `regex.pcre.replace_all` PR (port the `headers_test.v` assertions), then
      try dropping `regex.cc`
- [ ] §1.6 `os.fstat`
- [ ] §3.4 measure borrowed `string.bytes()` — then simplify `is_token`,
      `invalid_controls` and the header scans
- [ ] §3.1 measure `strings.Builder` with read cursor + `swap`
- [ ] §3.9 `json2` encoder API, rewrite `log.Config.encode`
- [x] §3.5 `log.parse_duration` delegates to `time.parse_duration`; only Caddy's `d`
      rewrite remains
- [x] Use V from git only; remove the release compatibility workflow
- [ ] §1.4 streaming encoder, then delete `encode.h` + `log/writer.h`
- [ ] §1.1 make `picoev` core public (`loop_once`, per-fd data, no HTTP), then
      delete the event-loop half of `platform*.h`
- [ ] §1.3 concurrent h2 server, then delete `http2.h`
- [ ] §5 module split, step 1 (`core`)
