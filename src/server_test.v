module main

import os
import json2
import time

#include "@VMODROOT/tests/support.h"

fn C.vaddy_nonblock(int) int
fn C.vaddy_test_tls_client(int, &char) voidptr
fn C.vaddy_test_tls_connect(voidptr) int
fn C.vaddy_test_peak_rss() i64
fn C.vaddy_test_cpu_us() i64
fn C.vaddy_test_socket_buffers(int) int

struct Harness {
mut:
	s        Server
	c        &Connection = unsafe { nil }
	client   int
	upstream int
}

fn socket_pair() ![]int {
	mut fds := []i64{len: 2}
	if C.vaddy_wakeup_pair(fds.data) != 0 {
		return error('socketpair failed')
	}
	assert C.vaddy_nonblock(fds[0]) == 0
	assert C.vaddy_nonblock(fds[1]) == 0
	assert C.vaddy_test_socket_buffers(fds[0]) == 0
	assert C.vaddy_test_socket_buffers(fds[1]) == 0
	return fds.map(int(it))
}

fn harness() !Harness {
	front := socket_pair()!
	back := socket_pair()!
	cfg := parse_config(os.read_file(os.join_path(@VMODROOT, 'Caddyfile'))!.replace('example.org', 'http://localhost'))!
	mut c := &Connection{ fd: front[0], backend: back[0], backend_name: 'localhost:8001', ip: '127.0.0.1', last_activity: mono_ms(), started: mono_ms() }
	mut s := Server{ cfg: cfg, queue: C.vaddy_queue(), http_fd: -1 }
	s.clients[c.fd] = c
	s.owners[c.fd] = c.fd
	s.owners[c.backend] = c.fd
	return Harness{s, c, front[1], back[1]}
}

fn send_text(fd int, data string) {
	assert C.vaddy_send(fd, data.str, uint(data.len), 0) == data.len
}

fn receive(fd int) string {
	mut data := []u8{}
	mut buf := [65536]u8{}
	for {
		n := C.vaddy_recv(fd, &buf[0], uint(buf.len), 0)
		if n <= 0 { break }
		data << buf[..n]
	}
	return data.bytestr()
}

fn (mut h Harness) pump() ! {
	for _ in 0 .. 3 {
		// Windows uses loopback TCP pairs; allow delivery between nonblocking pumps.
		$if windows { time.sleep(time.millisecond) }
		h.s.pump(mut h.c, h.c.fd)!
		if h.c.backend >= 0 { h.s.pump(mut h.c, h.c.backend)! }
	}
	$if windows { time.sleep(time.millisecond) }
}

fn (mut h Harness) close() {
	h.s.close_client(mut h.c)
	C.vaddy_close(h.client)
	C.vaddy_close(h.upstream)
	C.vaddy_queue_close(h.s.queue)
}

fn test_proxy_socket_io_rewrite_keepalive_pipeline_headers() ! {
	mut h := harness()!
	defer { h.close() }
	send_text(h.client, 'GET /assets/a.js?q=1 HTTP/1.1\r\nHost: localhost\r\n\r\nGET /favicon.ico HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	first := receive(h.upstream)
	assert first.starts_with('GET /static/assets/a.js?q=1 HTTP/1.1\r\n')
	assert !first.contains('favicon')
	send_text(h.upstream, 'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Opener-Policy: same-origin\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\none')
	h.pump()!
	response := receive(h.client)
	assert response.ends_with('\r\n\r\none')
	assert !response.to_lower().contains('cross-origin')
	assert response.count('Set-Cookie') == 2
	assert receive(h.upstream).starts_with('GET /static/assets/favicon.ico HTTP/1.1\r\n')
	send_text(h.upstream, 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\ntwo\r\n0\r\n\r\n')
	h.pump()!
	assert receive(h.client).ends_with('3\r\ntwo\r\n0\r\n\r\n')
	assert h.c.requests == 2
	assert !h.c.dead
}

fn test_proxy_streams_large_request_and_response_with_backpressure() ! {
	mut h := harness()!
	defer { h.close() }
	send_text(h.client, 'POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1048576\r\n\r\n')
	h.pump()!
	assert receive(h.upstream).starts_with('POST /upload')
	chunk := 'x'.repeat(4096)
	for _ in 0 .. 256 {
		send_text(h.client, chunk)
		h.pump()!
		assert receive(h.upstream) == chunk
	}
	assert h.c.request.frame.done
	send_text(h.upstream, 'HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\n\r\n')
	h.pump()!
	assert receive(h.client).starts_with('HTTP/1.1 200')
	for _ in 0 .. 256 {
		send_text(h.upstream, chunk)
		h.pump()!
		assert receive(h.client) == chunk
		assert h.c.to_client.data.cap <= buffer_limit * 2
		assert h.c.response_buffer.data.cap <= buffer_limit * 2
	}
	assert h.c.requests == 1
}

fn test_websocket_upgrade_and_expect_continue() ! {
	mut h := harness()!
	defer { h.close() }
	send_text(h.client, 'GET /ws HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n')
	h.pump()!
	assert receive(h.upstream).contains('Upgrade: websocket')
	send_text(h.upstream, 'HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nhello')
	h.pump()!
	assert receive(h.client).ends_with('hello')
	send_text(h.client, 'opaque\x00bytes')
	h.pump()!
	assert receive(h.upstream) == 'opaque\x00bytes'
	assert h.c.tunnel
}

fn test_reactor_readiness_registration() ! {
	mut h := harness()!
	defer { h.close() }
	h.s.update_interests(mut h.c)!
	send_text(h.client, 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
	mut events := [8]C.vaddy_event{}
	n := C.vaddy_wait(h.s.queue, &events[0], events.len, 100)
	assert n > 0 && events[0].fd == h.c.fd
	h.pump()!
	assert receive(h.upstream).starts_with('GET / HTTP/1.1')
}

fn test_internal_tls_issuance_handshake_and_reload() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-tls-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	C.vaddy_private_files()
	cfg := parse_config('localhost {\n tls internal\n reverse_proxy localhost:8001\n}')!
	opts := Options{ data: dir }
	exe := openssl_executable()!
	assert certificate_due(cfg, opts)
	provision_certificate(cfg, opts, exe)!
	assert !certificate_due(cfg, opts)
	mut h := harness()!
	defer { h.close() }
	h.s.cfg = cfg
	h.s.opts = opts
	h.s.cert_file = os.join_path(dir, 'current')
	h.s.reload_certificate()
	assert h.s.ctx != unsafe { nil }
	defer { C.vaddy_tls_ctx_free(h.s.ctx) }
	h.c.tls = C.vaddy_tls_new(h.s.ctx, h.c.fd)
	h.c.handshake = true
	client_tls := C.vaddy_test_tls_client(h.client, &char(os.join_path(dir, 'pki', 'root.crt').str))
	assert client_tls != unsafe { nil }
	defer { C.vaddy_tls_free(client_tls) }
	mut connected := false
	for _ in 0 .. 100 {
		if !connected {
			r := C.vaddy_test_tls_connect(client_tls)
			if r == 1 {
				connected = true
			} else {
				assert C.vaddy_tls_error(client_tls, r) in [2, 3]
			}
		}
		h.pump()!
		if connected && !h.c.handshake { break }
	}
	assert connected && !h.c.handshake
	request := 'GET /secure HTTP/1.1\r\nHost: localhost\r\n\r\n'
	assert C.vaddy_tls_write(client_tls, request.str, request.len) == request.len
	h.pump()!
	assert receive(h.upstream).contains('X-Forwarded-Proto: https')
	old := h.s.ctx
	provision_certificate(cfg, opts, exe)!
	h.s.reload_certificate()
	assert h.s.ctx != old
	send_text(h.upstream, 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
	h.pump()!
	mut buffer := [4096]u8{}
	n := C.vaddy_tls_read(client_tls, &buffer[0], buffer.len)
	assert n > 0
	assert buffer[..n].bytestr().ends_with('\r\n\r\nok')
	// Fill the TLS socket and application queues before allowing the client to read.
	// This exercises SSL_ERROR_WANT_WRITE retries while subsequent upstream data arrives.
	assert C.vaddy_tls_write(client_tls, request.str, request.len) == request.len
	h.pump()!
	assert receive(h.upstream).contains('/secure')
	send_text(h.upstream, 'HTTP/1.1 200 OK\r\nContent-Length: 262144\r\n\r\n')
	chunk := 'z'.repeat(4096)
	mut sent := 0
	for _ in 0 .. 100 {
		amount := C.vaddy_send(h.upstream, chunk.str, uint(chunk.len), 0)
		if amount > 0 { sent += amount }
		h.pump()!
		if amount < 0 { break }
	}
	assert sent < 262144
	assert h.c.to_client.len() <= buffer_limit
	assert h.c.response_buffer.len() <= buffer_limit
	assert h.c.write_len > 0
	mut received := []u8{}
	for _ in 0 .. 10000 {
		if sent < 262144 {
			amount := C.vaddy_send(h.upstream, chunk.str, uint(if 262144 - sent < chunk.len {
				262144 - sent
			} else {
				chunk.len
			}), 0)
			if amount > 0 { sent += amount }
		}
		h.pump()!
		r := C.vaddy_tls_read(client_tls, &buffer[0], buffer.len)
		if r > 0 {
			received << buffer[..r]
		} else {
			assert C.vaddy_tls_error(client_tls, r) in [2, 3]
		}
		if received.len >= 262144 + 43 { break }
	}
	assert sent == 262144
	assert received.bytestr().all_after('\r\n\r\n') == 'z'.repeat(262144)
	assert !h.c.dead
}

fn test_redirect_http01_and_unknown_host() ! {
	mut h := harness()!
	defer { h.close() }
	dir := os.join_path(os.temp_dir(), 'vaddy-challenge-${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'challenges'))!
	defer { os.rmdir_all(dir) or {} }
	h.s.opts.data = dir
	h.s.cfg.sites[0].plain = false
	os.write_file(os.join_path(dir, 'challenges', 'token-0123456789abcdef'), 'token.thumbprint')!
	send_text(h.client, 'GET /.well-known/acme-challenge/token-0123456789abcdef HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	assert receive(h.client).ends_with('\r\n\r\ntoken.thumbprint')
	mut redir := harness()!
	defer { redir.close() }
	redir.s.cfg.sites[0].plain = false
	send_text(redir.client, 'GET /assets/a.js?v=1 HTTP/1.1\r\nHost: localhost:80\r\n\r\n')
	redir.pump()!
	assert receive(redir.client).contains('Location: https://localhost/assets/a.js?v=1\r\n')
	mut unknown := harness()!
	defer { unknown.close() }
	send_text(unknown.client, 'GET / HTTP/1.1\r\nHost: attacker.example\r\n\r\n')
	unknown.pump()!
	assert receive(unknown.client).starts_with('HTTP/1.1 421')
}

fn test_benchmark_socketpair_proxy() ! {
	if os.getenv('VADDY_BENCH') == '' { return }
	mut h := harness()!
	defer { h.close() }
	request := 'GET /assets/app.js HTTP/1.1\r\nHost: localhost\r\n\r\n'
	response := 'HTTP/1.1 200 OK\r\nContent-Length: 512\r\n\r\n' + 'x'.repeat(512)
	mut buf := [4096]u8{}
	gc_collect()
	count := 100000
	start := mono_ms()
	cpu_start := C.vaddy_test_cpu_us()
	for _ in 0 .. count {
		// Each connection has a 1000-request cap, so reset the test counter to benchmark steady reuse.
		h.c.requests = 0
		send_text(h.client, request)
		h.s.pump(mut h.c, h.c.fd)!
		assert C.vaddy_recv(h.upstream, &buf[0], uint(buf.len), 0) > 0
		send_text(h.upstream, response)
		h.s.pump(mut h.c, h.c.backend)!
		assert C.vaddy_recv(h.client, &buf[0], uint(buf.len), 0) == response.len
	}
	elapsed := mono_ms() - start
	cpu := C.vaddy_test_cpu_us() - cpu_start
	println('socket-pair proxy: ${count} requests, ${elapsed} ms, ${i64(count) * 1000 / elapsed} requests/s; CPU ${f64(cpu) / 1000000:.3f}s (${f64(cpu) / f64(count):.2f} us/request, ${f64(cpu) / f64(elapsed) / 10:.1f}% of one core); peak RSS ${C.vaddy_test_peak_rss() / 1024} KiB (test process, includes client, backend, TLS/certificate tests)')
}

fn test_workers_distribute_connections_and_share_admission_limit() ! {
	cfg := parse_config('http://localhost {\n reverse_proxy localhost:8001\n}')!
	mut s := Server{ cfg: cfg, opts: Options{ workers: 2, max_connections: 4 }, queue: C.vaddy_queue() }
	defer { C.vaddy_queue_close(s.queue) }
	s.start_workers()!
	defer {
		s.stop_workers()
		for _, mut c in s.clients.clone() { s.close_client(mut c) }
	}
	mut fronts := []int{}
	mut backs := []int{}
	defer {
		for fd in fronts { C.vaddy_close(fd) }
		for fd in backs { C.vaddy_close(fd) }
	}
	for _ in 0 .. 5 {
		front := socket_pair()!
		back := socket_pair()!
		fronts << front[1]
		backs << back[1]
		mut c := &Connection{ fd: front[0], backend: back[0], backend_name: 'localhost:8001', ip: '127.0.0.1', started: mono_ms(), last_activity: mono_ms() }
		s.dispatch_client(mut c)
	}
	assert s.active_clients() == 4 // The fifth connection is rejected globally.
	assert s.clients.len == 2 // The other two belong to the second reactor.
	for fd in fronts[..4] { send_text(fd, 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n') }
	mut replies := []string{len: 4}
	mut responded := []bool{len: 4}
	for _ in 0 .. 1000 {
		for _, mut c in s.clients.clone() {
			s.pump(mut c, c.fd)!
			if c.backend >= 0 { s.pump(mut c, c.backend)! }
			s.update_interests(mut c)!
		}
		for i in 0 .. 4 {
			request := receive(backs[i])
			if request != '' {
				assert request.starts_with('GET / HTTP/1.1')
				send_text(backs[i], 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
				responded[i] = true
			}
			replies[i] += receive(fronts[i])
		}
		if replies.all(it.ends_with('\r\n\r\nok')) { break }
		time.sleep(time.millisecond)
	}
	assert responded.all(it), 'responded=${responded}, replies=${replies}, active=${s.active_clients()}'
	assert replies.all(it.ends_with('\r\n\r\nok'))
	s.stop_workers()
	for _, mut c in s.clients.clone() { s.close_client(mut c) }
	assert s.active_clients() == 0
}


fn test_header_edits_on_proxy_keepalive_and_local_response() ! {
	mut h := harness()!
	defer { h.close() }
	h.s.cfg = parse_config('http://localhost {\n header {\n X-Site yes\n -Server\n ?X-Existing default\n +Set-Cookie extra=1\n }\n request_header X-Client {remote_host}\n handle {\n header X-Path {uri}\n reverse_proxy localhost:8001 {\n header_up Host app.internal\n header_up -X-Secret\n header_up X-Forwarded-For configured\n header_down X-Backend replaced\n }\n }\n}')!
	for path in ['/first', '/second?literal={host}'] {
		send_text(h.client, 'GET ${path} HTTP/1.1\r\nHost: localhost\r\nX-Secret: password\r\n\r\n')
		h.pump()!
		request := receive(h.upstream)
		assert request.contains('Host: app.internal\r\n')
		assert request.contains('X-Client: 127.0.0.1\r\n')
		assert request.contains('X-Forwarded-For: configured\r\n')
		assert !request.contains('password')
		send_text(h.upstream, 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nServer: backend\r\nX-Existing: original\r\nX-Backend: old\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nok')
		h.pump()!
		response := receive(h.client)
		assert !response.contains('Server:')
		assert response.contains('X-Existing: original\r\n')
		assert response.contains('X-Site: yes\r\n')
		assert response.contains('X-Path: ${path}\r\n')
		assert response.contains('X-Backend: replaced\r\n')
		assert response.count('Set-Cookie:') == 3
		assert response.ends_with('\r\n\r\nok')
	}
	h.s.cfg.sites[0].plain = false
	send_text(h.client, 'HEAD /redirect HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	response := receive(h.client)
	assert response.contains('X-Site: yes\r\n')
	assert response.starts_with('HTTP/1.1 308')
}

fn test_header_edit_validation_and_output_limits() ! {
	for directive in ['header Content-Length 5', 'header +Connection close', 'request_header ?X-Foo bar', 'header Bad:Name x', 'header X-Test "[" replacement', 'header X-Test "bad\rvalue"'] {
		if _ := parse_config('http://localhost {\n ${directive}\n reverse_proxy localhost:8001\n}') { assert false, directive }
	}
	mut b := Buffer{}
	b.write_string('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n')
	original := b.bytes().bytestr()
	edits := [parse_header_edit(['X-Big', '{uri}{uri}'], false, false)!]
	if _ := edit_headers_for_test(mut b, edits, HeaderValues{uri: 'x'.repeat(header_limit)}) { assert false }
	assert b.bytes().bytestr() == original
}

fn edit_headers_for_test(mut b Buffer, edits []HeaderEdit, values HeaderValues) !bool {
	edit_header_buffer(mut b, edits, values)!
	return true
}

fn test_custom_redirects_precedence_and_head() ! {
	for method in ['GET', 'HEAD', 'POST'] {
		mut h := harness()!
		h.s.cfg = parse_config('http://localhost {\n header >X-Site yes\n reverse_proxy localhost:8001\n @old path /old /old/*\n redir @old https://new.example{uri} permanent\n handle /local {\n header X-Local yes\n redir * /target 307\n }\n}')!
		send_text(h.client, '${method} /old?q=1 HTTP/1.1\r\nHost: localhost\r\n\r\n')
		h.pump()!
		response := receive(h.client)
		assert response.starts_with('HTTP/1.1 301 Moved Permanently\r\n')
		assert response.contains('Location: https://new.example/old?q=1\r\n')
		assert response.contains('X-Site: yes\r\n')
		assert response.ends_with('\r\n\r\n')
		assert receive(h.upstream) == ''
		h.close()
	}
	mut h := harness()!
	defer { h.close() }
	h.s.cfg = parse_config('http://localhost {\n handle /local {\n header X-Local yes\n redir * /target 307\n }\n}')!
	send_text(h.client, 'GET /local HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	response := receive(h.client)
	assert response.starts_with('HTTP/1.1 307')
	assert response.contains('Location: /target\r\n')
	assert response.contains('X-Local: yes\r\n')
}

fn test_access_logs_once_per_request_and_aborted_response() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-log-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'access.jsonl')
	mut h := harness()!
	h.s.cfg = parse_config('http://localhost {\n log {\n output file "${path}"\n format json\n }\n redir /old /new 308\n reverse_proxy localhost:8001\n}')!
	h.s.access_logs = prepare_access_logs(h.s.cfg)!
	defer { close_access_logs(h.s.access_logs) }
	defer { h.close() }
	for _ in 0 .. 2 {
		send_text(h.client, 'GET /quoted?x="secret" HTTP/1.1\r\nHost: localhost\r\nAuthorization: secret\r\nCookie: private\r\n\r\n')
		h.pump()!
		receive(h.upstream)
		send_text(h.upstream, 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
		h.pump()!
		response := receive(h.client)
		lines := os.read_lines(path)!
		record := json2.decode[AccessRecord](lines.last())!
		assert record.status == 200 && record.complete
		assert record.bytes_written == response.len
		assert record.uri == '/quoted?x="secret"'
		assert !lines.last().contains('Authorization') && !lines.last().contains('private')
	}
	assert os.read_lines(path)!.len == 2
	send_text(h.client, 'GET /aborted HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	receive(h.upstream)
	send_text(h.upstream, 'HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial')
	h.pump()!
	h.s.close_client(mut h.c)
	lines := os.read_lines(path)!
	assert lines.len == 3
	record := json2.decode[AccessRecord](lines[2])!
	assert record.status == 200 && !record.complete
	mut redirect := harness()!
	defer { redirect.close() }
	redirect.s.cfg = h.s.cfg
	redirect.s.access_logs = h.s.access_logs
	send_text(redirect.client, 'GET /old HTTP/1.1\r\nHost: localhost\r\n\r\n')
	redirect.pump()!
	assert json2.decode[AccessRecord](os.read_lines(path)!.last())!.status == 308
}

fn test_reload_retains_inflight_config_and_rolls_back_invalid_resources() ! {
	dir := os.join_path(os.temp_dir(), 'vaddy-reload-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	mut h := harness()!
	h.s.cfg = parse_config('http://localhost {\n header X-Generation old\n log {\n output file "${dir}/old.log"\n }\n reverse_proxy localhost:8001\n}')!
	h.s.runtime_store = &RuntimeStore{}
	h.s.runtime_store.current = prepare_runtime(h.s.cfg, 1, h.s.runtime_store.log_mutex)!
	h.c.backend_generation = 1
	defer { h.s.close_runtimes() }
	defer { h.close() }
	send_text(h.client, 'GET /inflight HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	assert receive(h.upstream).contains('/inflight')
	old := h.s.runtime_store.current
	assert old.users == 1
	for input in ['invalid', 'http://localhost {\n log {\n output file "${dir}/missing/no.log"\n }\n redir * /bad\n}', 'localhost {\n tls internal\n redir * /bad\n}'] {
		if _ := replace_config_for_test(mut h.s, input) { assert false }
		assert h.s.runtime_store.current == old
	}
	h.s.replace_config('http://localhost {\n header X-Generation new\n log {\n output file "${dir}/new.log"\n }\n redir * /new 307\n}')!
	h.s.reap_runtimes()
	assert h.s.retired.len == 1 && old.users == 1
	send_text(h.upstream, 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
	h.pump()!
	assert receive(h.client).contains('X-Generation: old\r\n')
	assert json2.decode[AccessRecord](os.read_lines('${dir}/old.log')![0])!.uri == '/inflight'
	assert old.users == 0
	h.s.reap_runtimes()
	assert h.s.retired.len == 0
	send_text(h.client, 'GET /next HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	response := receive(h.client)
	assert response.starts_with('HTTP/1.1 307') && response.contains('X-Generation: new\r\n')
	assert json2.decode[AccessRecord](os.read_lines('${dir}/new.log')![0])!.uri == '/next'
}

fn replace_config_for_test(mut s Server, input string) !bool {
	s.replace_config(input)!
	return true
}

fn test_redirect_body_drain_pipeline_and_dynamic_codes() ! {
	mut h := harness()!
	defer { h.close() }
	h.s.cfg = parse_config('http://localhost {\n redir * /new {query.code}\n}')!
	send_text(h.client, 'POST /old?code=307 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\n\r\nabcGET /old?code=308 HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	response := receive(h.client)
	assert response.count('HTTP/1.1') == 2
	assert response.contains('HTTP/1.1 307') && response.contains('HTTP/1.1 308')
	assert !h.c.dead
	send_text(h.client, 'GET /old?code=oops HTTP/1.1\r\nHost: localhost\r\n\r\n')
	h.pump()!
	assert receive(h.client).starts_with('HTTP/1.1 500')
}
