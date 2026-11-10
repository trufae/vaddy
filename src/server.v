module main

import os
import time
import sync.stdatomic

struct Options {
mut:
	acme_transport         AcmeTransport = acme_http
	config                 string        = 'Caddyfile'
	data                   string
	bind                   string = '::'
	max_connections        int    = 512
	workers                int    = 1
	max_keepalive_requests int    = 1000
	idle_timeout           int    = 60
	header_timeout         int    = 15
	http_port              int
	https_port             int
	staging                bool
}

@[heap]
struct Connection {
mut:
	runtime &Runtime = unsafe { nil }
	backend_generation i64
	access_log &AccessLog = unsafe { nil }
	access_logged bool
	log_status int
	log_started i64
	log_upstream string
	log_size i64
	log_bytes_read i64
	log_name string
	log_empty_content_type bool
	log_response_fields []Field
	remote_port string
	fd              int
	counted         bool
	backend         int = -1
	backend_tls     voidptr
	backend_handshake bool
	backend_handshake_want int = 2
	backend_read_want int = 1
	backend_write_want int = 2
	backend_stop_write bool
	backend_write_len int
	backend_name    string
	connecting      bool
	ip              string
	tls             voidptr
	handshake       bool
	handshake_want  int = 1
	read_want       int = 1
	write_want      int = 2
	write_len       int
	request_buffer  Buffer
	response_buffer Buffer
	to_backend      Buffer
	to_client       Buffer
	request         Message
	response        Message
	have_request    bool
	have_response   bool
	close_after     bool
	tunnel          bool
	dead            bool
	local           bool
	site            int = -1
	response_headers []HeaderEdit
	header_values HeaderValues
	requests        int
	last_activity   i64
	started         i64
}

struct Server {
mut:
	runtime_store &RuntimeStore = unsafe { nil }
	retired []&Runtime
	run_id string
	cfg           Config
	opts          Options
	queue         int
	http_fd       int         = -1
	pool          &WorkerPool = &WorkerPool{}
	control_fd    int         = -1
	incoming      chan &Connection
	next_worker   int
	https_fd      int = -1
	ctx           voidptr
	cert_file     string
	key_file      string
	cert_stamp    string
	clients       map[int]&Connection
	owners        map[int]int
	watches       map[int]int
	access_logs   map[string]&AccessLog
	backends      map[string]Backend
	last_tick     i64
	accept_retry  i64
	draining      bool
	drain_started i64
}

fn mono_ms() i64 { return time.sys_mono_now() / 1000000 }

fn (mut s Server) watch(fd int, flags int) ! {
	if fd < 0 { return }
	old := s.watches[fd]
	if old == flags { return }
	if C.vaddy_watch(s.queue, fd, old, flags) < 0 {
		return error('cannot update event registration for fd ${fd}')
	}
	// Keep disabled descriptors in the table until close. Removing and reinserting
	// them on every request repeatedly compacts/grows V's map backing arrays.
	s.watches[fd] = flags
}

fn (mut s Server) close_backend(mut c Connection) {
	if c.backend < 0 { return }
	s.watch(c.backend, 0) or {}
	s.watches.delete(c.backend)
	s.owners.delete(c.backend)
	if c.backend_tls != unsafe { nil } { C.vaddy_tls_free(c.backend_tls) }
	c.backend_tls = unsafe { nil }
	c.backend_handshake = false
	c.backend_write_len = 0
	c.backend_stop_write = false
	c.backend_read_want = 1
	c.backend_write_want = 2
	C.vaddy_close(c.backend)
	c.backend = -1
	c.connecting = false
	c.backend_name = ''
}

fn (mut s Server) close_client(mut c Connection) {
	if c.fd < 0 { return }
	s.log_access(mut c, false)
	release_runtime(mut c)
	s.close_backend(mut c)
	s.watch(c.fd, 0) or {}
	s.watches.delete(c.fd)
	if c.tls != unsafe { nil } {
		C.vaddy_tls_free(c.tls)
		c.tls = unsafe { nil }
	}
	C.vaddy_close(c.fd)
	s.clients.delete(c.fd)
	s.owners.delete(c.fd)
	c.dead = true
	c.fd = -1
	if c.counted {
		stdatomic.sub_i64(&s.pool.active, 1)
		c.counted = false
	}
}

fn (mut s Server) respond(mut c Connection, code int, reason string, body string, extra string) {
	s.respond_options(mut c, code, reason, body, extra, false, 'text/plain; charset=utf-8')
}

fn (mut s Server) respond_options(mut c Connection, code int, reason string, body string, extra string, keepalive bool, content_type string) {
	s.close_backend(mut c)
	c.to_client.clear()
	c.to_backend.clear()
	c.log_status = code
	mut response_body := body
	mut header := Buffer{}
	c.close_after = !keepalive || c.request.close || s.draining || c.requests >= s.opts.max_keepalive_requests - 1 || c.request.expect || c.request.frame.kind == .chunked || c.request.frame.remaining > 262144
	connection := if c.close_after { 'Connection: close\r\n' } else { '' }
	content := if content_type == '' { '' } else { 'Content-Type: ${content_type}\r\n' }
	length := if code in [204, 304] || (keepalive && c.request.method == 'HEAD' && body == '') { '' } else { 'Content-Length: ${body.len}\r\n' }
	if code in [204, 304] { response_body = '' }
	header.write_string('HTTP/1.1 ${code} ${reason}\r\n${length}${content}${connection}${extra}\r\n')
	response_header_buffer(mut header, c.response_headers, c.header_values, code, true) or {
		// Never emit malformed or oversized configured headers, including on errors.
		header.clear()
		c.log_status = 500
		c.close_after = true
		response_body = ''
		header.write_string('HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
	}
	c.log_empty_content_type = keepalive && content_type == ''
	c.log_response_fields = buffer_header_fields(header).filter(it.lower !in ['content-length', 'connection'])
	c.log_size = response_body.len
	c.to_client.add(header.bytes())
	if c.request.method != 'HEAD' { c.to_client.add(response_body.bytes()) }
	c.local = true
	c.have_response = true
	c.response = Message{frame: Framing{done: true}}
}

fn (mut s Server) accept_clients(listener int, tls bool) {
	if s.accept_retry > 0 { return }
	for _ in 0 .. 32 {
		if s.active_clients() >= s.opts.max_connections {
			s.pause_accepts()
			break
		}
		mut ip := [128]char{}
		fd := C.vaddy_accept(listener, &ip[0], ip.len)
		if fd < 0 {
			// Exhausted descriptors must not leave a readable listener spinning the reactor.
			if C.vaddy_again() == 0 { s.pause_accepts() }
			break
		}
		if tls && s.ctx == unsafe { nil } {
			C.vaddy_close(fd)
			continue
		}
		now := mono_ms()
		mut c := &Connection{ fd: fd, remote_port: C.vaddy_peer_port(fd).str(), ip: unsafe { cstring_to_vstring(&ip[0]) }, last_activity: now, started: now }
		if tls {
			c.tls = C.vaddy_tls_new(s.ctx, fd)
			if c.tls == unsafe { nil } {
				C.vaddy_close(fd)
				continue
			}
			c.handshake = true
		}
		s.dispatch_client(mut c)
	}
}

fn (mut s Server) pause_accepts() {
	s.accept_retry = mono_ms() + 1000
	s.watch(s.http_fd, 0) or {}
	s.watch(s.https_fd, 0) or {}
}

fn (mut s Server) begin_request(mut c Connection) !bool {
	raw := c.request_buffer.bytes().bytestr()
	end := raw.index('\r\n\r\n') or {
		if raw.len >= header_limit {
			s.respond(mut c, 431, 'Request Header Fields Too Large', 'Headers too large\n', '')
		}
		return false
	}
	m := parse_message_reuse(raw[..end + 4], true, false, c.request.fields) or {
		s.respond(mut c, 400, 'Bad Request', 'Bad Request\n', '')
		return false
	}
	c.request_buffer.skip(end + 4)
	c.request = m
	c.have_request = true
	c.access_logged = false
	c.log_status = 0
	c.log_started = time.sys_mono_now()
	c.log_size = 0
	c.log_empty_content_type = false
	c.log_bytes_read = 0
	c.log_response_fields = []Field{}
	c.log_upstream = ''
	if s.runtime_store != unsafe { nil } { c.runtime = s.runtime_store.acquire() }
	cfg := if c.runtime == unsafe { nil } { s.cfg } else { c.runtime.cfg }
	backends := if c.runtime == unsafe { nil } { s.backends } else { c.runtime.backends }
	logs := if c.runtime == unsafe { nil } { s.access_logs } else { c.runtime.logs }
	c.site = cfg.site_index(m.host)
	if c.site < 0 {
		s.respond(mut c, 421, 'Misdirected Request', 'Unknown host\n', '')
		return false
	}
	site := cfg.sites[c.site]
	c.log_name = site.log_name
	c.access_log = logs[site.log_output] or { unsafe { nil } }
	c.response_headers = site.response_headers.clone()
	c.header_values = HeaderValues{uri: m.uri, method: m.method, fields: m.fields.clone(), host: m.host.all_before(':'), hostport: m.host, scheme: if c.tls == unsafe { nil } { 'http' } else { 'https' }, remote_host: c.ip, remote_port: c.remote_port}
	if c.tls == unsafe { nil } {
		if m.uri.all_before('?').starts_with('/.well-known/acme-challenge/') && m.method in [
			'GET',
			'HEAD',
		] {
			token := m.uri.all_before('?').all_after_last('/')
			if token.len >= 16 && token.len <= 256 && token.bytes().all(it.is_alnum() || it in [
				u8(`-`),
				`_`,
			]) {
				body := os.read_file(os.join_path(s.opts.data, 'challenges', token)) or { '' }
				if body != '' && body.len < 1024 {
					s.respond(mut c, 200, 'OK', body, '')
					return false
				}
			}
			s.respond(mut c, 404, 'Not Found', 'Challenge not found\n', '')
			return false
		}
		if !site.plain {
			port := if cfg.https_port == 443 { '' } else { ':${cfg.https_port}' }
			host := m.host.all_before(':').to_lower().trim_right('.')
			s.respond(mut c, 308, 'Permanent Redirect', '', 'Location: https://${host}${port}${m.uri}\r\n')
			return false
		}
	} else if site.plain {
		s.respond(mut c, 421, 'Misdirected Request', 'HTTP-only host\n', '')
		return false
	}
	route := site.route_for(m.uri) or {
		s.respond(mut c, 404, 'Not Found', 'Not Found\n', '')
		return false
	}
	c.response_headers << route.response_headers
	if route.redirect != '' {
		s.redirect_response(mut c, route)!
		return false
	}
	c.log_upstream = route.upstream
	c.header_values.upstream_hostport = route.upstream.trim_string_left('https://')
	generation := if c.runtime == unsafe { nil } { i64(0) } else { c.runtime.id }
	if c.backend >= 0 && (c.backend_generation != generation || c.backend_name != route.backend_key() || C.vaddy_socket_alive(c.backend) == 0) {
		s.close_backend(mut c)
	}
	if c.backend < 0 {
		backend := backends[route.backend_key()] or { return error('unresolved upstream') }
		c.backend = C.vaddy_connect(backend.address)
		if c.backend < 0 {
			s.respond(mut c, 502, 'Bad Gateway', 'Bad Gateway\n', '')
			return false
		}
		c.connecting = true
		c.started = mono_ms()
		c.backend_name = route.backend_key()
		c.backend_generation = generation
		if backend.ctx != unsafe { nil } {
			c.backend_tls = C.vaddy_upstream_tls(backend.ctx, c.backend, &char(backend.name.str))
			if c.backend_tls == unsafe { nil } { return error('cannot create upstream TLS session') }
			c.backend_handshake = true
			c.backend_handshake_want = 2
		}
		s.owners[c.backend] = c.fd
	}
	mut edits := site.request_headers.clone()
	edits << route.request_headers
	mut upstream_request := m
	upstream_request.fields = m.fields.clone()
	apply_header_edits(mut upstream_request.fields, edits.filter(!it.proxy), c.header_values, 0, false)!
	hosts := upstream_request.fields.filter(it.lower == 'host')
	upstream_request.host = if hosts.len > 0 { hosts.last().value } else { '' }
	upstream_request.fields = upstream_request.fields.filter(it.lower != 'host')
	fallback_host := route.upstream.trim_string_left('https://')
	host := if route.upstream.starts_with('https://') || upstream_request.host == '' { fallback_host } else { upstream_request.host }
	upstream_request.fields << Field{'Host', 'host', host}
	c.to_backend.request_header(upstream_request, rewrite_uri(m.uri, route.rewrite), c.ip, c.tls != unsafe { nil }, '')
	edit_header_buffer(mut c.to_backend, edits.filter(it.proxy), c.header_values)!
	// Host is represented separately by Go's request type: an append replaces it.
	mut wire_fields := buffer_header_fields(c.to_backend)
	wire_hosts := wire_fields.filter(it.lower == 'host')
	wire_fields = wire_fields.filter(it.lower != 'host')
	wire_fields << Field{'Host', 'host', if wire_hosts.len > 0 && wire_hosts.last().value != '' { wire_hosts.last().value } else { fallback_host }}
	write_header_fields(mut c.to_backend, wire_fields)!

	c.close_after = m.close || s.draining || c.requests >= s.opts.max_keepalive_requests - 1
	if m.expect && !m.frame.done { c.to_client.add('HTTP/1.1 100 Continue\r\n\r\n'.bytes()) }
	return true
}

fn (mut s Server) consume_request(mut c Connection) ! {
	if !c.have_request && !s.begin_request(mut c)! { return }
	if c.local {
		if !c.close_after && !c.request.frame.done {
			n := c.request.frame.consume(c.request_buffer.bytes())!
			c.request_buffer.skip(n)
		}
		return
	}
	if c.backend_stop_write || c.request.frame.done || c.request_buffer.len() == 0 { return }
	data := c.request_buffer.bytes()
	limit := if data.len < c.to_backend.room() { data.len } else { c.to_backend.room() }
	n := c.request.frame.consume(data[..limit])!
	c.log_bytes_read = c.request.frame.body_bytes
	c.to_backend.add(data[..n])
	c.request_buffer.skip(n)
}

fn (mut s Server) write_response_header(mut c Connection, m Message, close bool) ! {
	mut header := Buffer{}
	header.response_header(m, [], close)
	response_header_buffer(mut header, c.response_headers, c.header_values, m.status, false)!
	if m.status >= 200 || m.status == 101 { c.log_response_fields = buffer_header_fields(header).filter(it.lower !in ['connection', 'transfer-encoding']) }
	if c.to_client.room() < header.len() { return error('response header output exceeds buffer') }
	c.to_client.add(header.bytes())
}

fn (mut s Server) consume_response(mut c Connection) ! {
	for !c.have_response {
		raw := c.response_buffer.bytes().bytestr()
		end := raw.index('\r\n\r\n') or {
			if raw.len >= header_limit { return error('upstream headers too large') }
			return
		}
		mut m := parse_message_reuse(raw[..end + 4], false, c.request.method == 'HEAD', c.response.fields)!
		if c.to_client.room() < end + 128 { return }
		c.response_buffer.skip(end + 4)
		if m.status == 101 {
			if !c.request.upgrade || !m.upgrade { return error('unsolicited upgrade') }
			c.tunnel = true
			m.frame = Framing{ kind: .tunnel }
			c.request.frame = Framing{ kind: .tunnel }
		}
		if m.status < 200 && m.status != 101 {
			if m.status != 100 || !c.request.expect {
				s.write_response_header(mut c, m, false)!
			}
			continue
		}
		c.have_response = true
		c.log_status = m.status
		if !c.tunnel && (!c.request.frame.done || c.to_backend.len() > 0) {
			c.close_after = true
			c.backend_stop_write = true
			// Retain plaintext while OpenSSL has an outstanding write retry.
			if c.backend_write_len == 0 { c.to_backend.clear() }
		}
		if m.frame.kind == .eof { c.close_after = true }
		c.response = m
		s.write_response_header(mut c, m, c.close_after)!
	}
	if c.response_buffer.len() > 0 && c.to_client.room() > 0 {
		data := c.response_buffer.bytes()
		limit := if data.len < c.to_client.room() { data.len } else { c.to_client.room() }
		n := c.response.frame.consume(data[..limit])!
		if !c.tunnel { c.log_size = c.response.frame.body_bytes }
		c.to_client.add(data[..n])
		c.response_buffer.skip(n)
		if c.response.frame.done && c.response_buffer.len() > 0 {
			return error('unexpected data after upstream response')
		}
	}
}

fn (mut s Server) backend_eof(mut c Connection) ! {
	s.close_backend(mut c)
	if !c.have_response { return error('upstream closed before response headers') }
	if c.response.frame.kind == .eof {
		c.response.frame.done = true
	} else if c.tunnel {
		c.close_after = true
		c.response.frame.done = true
	} else if !c.response.frame.done {
		return error('upstream truncated response')
	}
}

fn (mut s Server) finish_request(mut c Connection) ! {
	if c.local && !c.close_after && !c.request.frame.done { return }
	if !c.have_response || !c.response.frame.done || c.to_client.len() > 0 { return }
	s.log_access(mut c, true)
	if c.close_after || s.draining {
		c.dead = true
		return
	}
	if c.response.close { s.close_backend(mut c) }
	c.requests++
	release_runtime(mut c)
	c.have_request = false
	c.local = false
	c.access_log = unsafe { nil }
	c.response_headers = []HeaderEdit{}
	c.header_values = HeaderValues{}
	c.have_response = false
	c.request = Message{ fields: c.request.fields }
	c.response = Message{ fields: c.response.fields }
	c.started = mono_ms()
	c.response_buffer.clear()
	if c.request_buffer.len() > 0 { s.consume_request(mut c)! }
}

fn (mut s Server) pump(mut c Connection, event_fd int) ! {
	if c.handshake {
		result := C.vaddy_tls_handshake(c.tls)
		if result == 1 {
			c.handshake = false
			c.last_activity = mono_ms()
		} else {
			err := C.vaddy_tls_error(c.tls, result)
			if err !in [2, 3] {
				c.dead = true
				return
			}
			c.handshake_want = if err == 2 { 1 } else { 2 }
			return
		}
	}
	if c.connecting && event_fd == c.backend {
		if C.vaddy_connected(c.backend) != 0 { return error('upstream connect failed') }
		c.connecting = false
	}
	if c.backend_handshake && !c.connecting {
		result := C.vaddy_upstream_handshake(c.backend_tls)
		if result == 1 {
			c.backend_handshake = false
			c.last_activity = mono_ms()
		} else {
			err := C.vaddy_tls_error(c.backend_tls, result)
			if err !in [2, 3] { return error('upstream TLS verification or handshake failed') }
			c.backend_handshake_want = if err == 2 { 1 } else { 2 }
		}
	}
	mut scratch := [16384]u8{}
	// Drain each ready input until EAGAIN, then wait for another readiness event.
	// OpenSSL may have records buffered even when the kernel socket is no longer
	// readable, so those records must also be allowed to drive the client read.
	mut client_readable := event_fd == c.fd || (c.tls != unsafe { nil } && C.vaddy_tls_has_pending(c.tls) != 0)
	mut backend_readable := event_fd == c.backend || (c.backend_tls != unsafe { nil } && C.vaddy_tls_has_pending(c.backend_tls) != 0)
	for _ in 0 .. 8 {
		mut progress := false
		if c.to_client.len() > 0 {
			data := c.to_client.bytes()
			mut n := 0
			if c.tls != unsafe { nil } {
				if c.write_len == 0 { c.write_len = data.len }
				n = C.vaddy_tls_write(c.tls, data.data, c.write_len)
				if n <= 0 {
					err := C.vaddy_tls_error(c.tls, n)
					if err !in [2, 3] {
						c.dead = true
						return
					}
					c.write_want = if err == 2 { 1 } else { 2 }
				} else {
					c.write_len = 0
					c.write_want = 2
				}
			} else {
				n = int(C.vaddy_send(c.fd, data.data, uint(data.len), 0))
				if n < 0 && C.vaddy_again() == 0 {
					c.dead = true
					return
				}
			}
			if n > 0 {
			c.to_client.skip(n)
				progress = true
			}
		}
		s.finish_request(mut c)!
		if c.dead { return }
		if !c.local && c.backend >= 0 && !c.connecting && !c.backend_handshake && !c.backend_stop_write && c.to_backend.len() > 0 {
			data := c.to_backend.bytes()
			mut n := 0
			if c.backend_tls != unsafe { nil } {
				if c.backend_write_len == 0 { c.backend_write_len = data.len }
				n = C.vaddy_tls_write(c.backend_tls, data.data, c.backend_write_len)
				if n <= 0 {
					err := C.vaddy_tls_error(c.backend_tls, n)
					if err !in [2, 3] { return error('upstream TLS write failed') }
					c.backend_write_want = if err == 2 { 1 } else { 2 }
				} else {
					c.backend_write_len = 0
					c.backend_write_want = 2
				}
			} else {
				n = int(C.vaddy_send(c.backend, data.data, uint(data.len), 0))
				if n < 0 && C.vaddy_again() == 0 { return error('upstream write failed') }
			}
			if n > 0 {
				c.to_backend.skip(n)
				progress = true
			}
		}
		if backend_readable && !c.local && c.have_request && c.backend >= 0 && !c.connecting && !c.backend_handshake && !(c.backend_write_len > 0 && c.backend_write_want == 1) && !c.response.frame.done && c.response_buffer.room() > 0 && c.to_client.room() >= 16384 {
			limit := if c.response_buffer.room() < scratch.len {
				c.response_buffer.room()
			} else {
				scratch.len
			}
			mut n := 0
			if c.backend_tls != unsafe { nil } {
				n = C.vaddy_tls_read(c.backend_tls, &scratch[0], limit)
				if n <= 0 {
					err := C.vaddy_tls_error(c.backend_tls, n)
					backend_readable = false
					if err == 6 {
						s.backend_eof(mut c)!
					} else if err in [2, 3] {
						c.backend_read_want = if err == 2 { 1 } else { 2 }
					} else { return error('upstream TLS read failed') }
				} else { c.backend_read_want = 1 }
			} else {
				n = int(C.vaddy_recv(c.backend, &scratch[0], uint(limit), 0))
				if n < 0 { backend_readable = false }
				if n < 0 && C.vaddy_again() == 0 { return error('upstream read failed') }
				if n == 0 { s.backend_eof(mut c)! }
			}
			if n > 0 {
				c.response_buffer.add(scratch[..n])
				progress = true
			}
		}
		if !c.local && c.response_buffer.len() > 0 { s.consume_response(mut c)! }
		if !c.local && !c.have_request && c.request_buffer.len() > 0 { s.consume_request(mut c)! }
		if c.have_request && !c.request.frame.done && c.request_buffer.len() > 0 && c.to_backend.room() > 0 {
			s.consume_request(mut c)!
		}
		can_read := (!c.local || !c.close_after) && (!c.have_request || (!c.request.frame.done && (!c.have_response || c.tunnel || c.local))) && c.request_buffer.room() >= 16384 && c.to_backend.room() >= 16384
		if client_readable && can_read && !(c.write_len > 0 && c.write_want == 1) {
			mut n := 0
			if c.tls != unsafe { nil } {
				n = C.vaddy_tls_read(c.tls, &scratch[0], scratch.len)
				if n <= 0 {
					err := C.vaddy_tls_error(c.tls, n)
					client_readable = false
					if err !in [2, 3] {
						c.dead = true
						return
					}
					c.read_want = if err == 2 { 1 } else { 2 }
				} else {
					c.read_want = 1
				}
			} else {
				n = int(C.vaddy_recv(c.fd, &scratch[0], uint(scratch.len), 0))
				if n < 0 { client_readable = false }
				if n == 0 || (n < 0 && C.vaddy_again() == 0) {
					c.dead = true
					return
				}
			}
			if n > 0 {
				if !c.have_request && c.request_buffer.len() == 0 { c.started = mono_ms() }
				c.request_buffer.add(scratch[..n])
				s.consume_request(mut c) or { s.respond(mut c, 400, 'Bad Request', 'Bad Request\n', '') }
				progress = true
			}
		}
		if !progress { break }
		c.last_activity = mono_ms()
	}
}

fn (mut s Server) update_interests(mut c Connection) ! {
	if c.dead {
		s.close_client(mut c)
		return
	}
	mut flags := 0
	if c.handshake {
		flags = c.handshake_want
	} else {
		if c.to_client.len() > 0 { flags |= c.write_want }
		if (!c.local || !c.close_after) && (!c.have_request || (!c.request.frame.done && (!c.have_response || c.tunnel || c.local))) && c.request_buffer.room() >= 16384 && c.to_backend.room() >= 16384 {
			flags |= c.read_want
		}
	}
	s.watch(c.fd, flags)!
	if c.backend >= 0 {
		mut back := 0
		if c.connecting {
			back = 2
		} else if c.backend_handshake {
			back = c.backend_handshake_want
		} else {
			if !c.backend_stop_write && c.to_backend.len() > 0 { back |= c.backend_write_want }
			if c.have_request && !c.response.frame.done && c.response_buffer.room() > 0 && c.to_client.room() >= 16384 {
				back |= c.backend_read_want
			}
		}
		s.watch(c.backend, back)!
	}
}

fn (mut s Server) reload_certificate() {
	if s.cert_file == '' { return }
	// Atomic publication changes the manifest; existing SSL objects retain the old context.
	mut cert := s.cert_file
	mut key := s.key_file
	mut stamp := ''
	if key == '' {
		stamp = os.read_file(s.cert_file) or { return }
		generation := stamp.trim_space()
		if !safe_generation(generation) { return }
		policy := os.read_file(os.join_path(s.opts.data, generation, 'policy')) or { return }
		if policy != cert_policy(s.cfg) { return }
		cert = os.join_path(s.opts.data, generation, 'fullchain.pem')
		key = os.join_path(s.opts.data, generation, 'key.pem')
	} else {
		stamp = '${os.file_last_mod_unix(cert)}:${os.file_last_mod_unix(key)}'
	}
	if stamp == s.cert_stamp { return }
	if C.vaddy_cert_seconds(&char(cert.str), 0) <= 0 {
		eprintln('vaddy: TLS certificate is missing, expired, or not yet valid: ${cert}')
		return
	}
	for domain in s.cfg.domains() {
		if C.vaddy_cert_host(&char(cert.str), &char(domain.str)) != 1 {
			eprintln('vaddy: TLS certificate does not cover ${domain}')
			return
		}
	}
	ctx := C.vaddy_tls_context(&char(cert.str), &char(key.str))
	if ctx == unsafe { nil } {
		eprintln('vaddy: cannot load TLS certificate ${cert}')
		return
	}
	old := s.ctx
	s.ctx = ctx
	s.cert_stamp = stamp
	if old != unsafe { nil } { C.vaddy_tls_ctx_free(old) }
	eprintln('vaddy: loaded TLS certificate for ${s.cfg.domains().join(', ')}')
}

fn (mut s Server) tick() {
	now := mono_ms()
	if now - s.last_tick < 1000 { return }
	s.last_tick = now
	if !s.draining {
		s.reload_certificate()
		if s.runtime_store != unsafe { nil } && s.control_fd < 0 {
			s.check_reload()
			s.reap_runtimes()
		}
	}
	for _, mut c in s.clients.clone() {
		in_headers := c.handshake || (!c.have_request && c.request_buffer.len() > 0) || c.connecting || c.backend_handshake
		if now - c.last_activity > i64(s.opts.idle_timeout) * 1000 || (in_headers && now - c.started > i64(s.opts.header_timeout) * 1000) || (s.draining && now - s.drain_started > 10000) {
			s.close_client(mut c)
		}
	}
	if !s.draining && s.accept_retry > 0 && now >= s.accept_retry && s.active_clients() < s.opts.max_connections {
		s.accept_retry = 0
		s.watch(s.http_fd, 1) or {}
		s.watch(s.https_fd, 1) or {}
	}
}

fn run_server(cfg Config, opts Options) ! {
	mut s := Server{ cfg: cfg, opts: opts, queue: C.vaddy_queue() }
	if s.queue < 0 { return error('cannot create event queue') }
	defer { C.vaddy_queue_close(s.queue) }
	s.runtime_store = &RuntimeStore{}
	s.runtime_store.current = prepare_runtime(cfg, 1, s.runtime_store.log_mutex)!
	s.backends = s.runtime_store.current.backends
	s.access_logs = s.runtime_store.current.logs
	defer { s.close_runtimes() }
	s.run_id = new_reload_id()!
	atomic_write(os.join_path(opts.data, 'run.id'), s.run_id)!
	defer { os.rm(os.join_path(opts.data, 'run.id')) or {} }
	s.http_fd = C.vaddy_listen(&char(opts.bind.str), &char(cfg.http_port.str().str))
	if s.http_fd < 0 {
		return error('cannot listen on ${opts.bind}:${cfg.http_port} (check permissions and existing listeners)')
	}
	defer { if s.http_fd >= 0 { C.vaddy_close(s.http_fd) } }
	s.watch(s.http_fd, 1)!
	if site := cfg.tls_site() {
		s.https_fd = C.vaddy_listen(&char(opts.bind.str), &char(cfg.https_port.str().str))
		if s.https_fd < 0 {
			return error('cannot listen on ${opts.bind}:${cfg.https_port} (check permissions and existing listeners)')
		}
		if site.tls_mode == 'manual' {
			s.cert_file = site.cert
			s.key_file = site.key
		} else {
			s.cert_file = os.join_path(opts.data, 'current')
		}
		s.reload_certificate()
		if site.tls_mode == 'manual' && s.ctx == unsafe { nil } {
			C.vaddy_close(s.https_fd)
			return error('invalid manual TLS certificate/key')
		}
		s.watch(s.https_fd, 1)!
		if site.tls_mode != 'manual' { spawn certificate_worker(cfg, opts) }
		eprintln('vaddy: HTTPS on ${opts.bind}:${cfg.https_port}; HTTP on ${opts.bind}:${cfg.http_port}')
	} else {
		eprintln('vaddy: HTTP on ${opts.bind}:${cfg.http_port}')
	}
	defer {
		for _, mut c in s.clients.clone() { s.close_client(mut c) }
		if s.https_fd >= 0 { C.vaddy_close(s.https_fd) }
		if s.ctx != unsafe { nil } { C.vaddy_tls_ctx_free(s.ctx) }
	}
	defer { s.stop_workers() }
	s.start_workers()!
	eprintln('vaddy: ${s.pool.threads.len + 1} event-loop worker(s), global limit ${opts.max_connections} clients')
	s.serve_events()!
}

fn (mut s Server) serve_events() ! {
	mut events := [256]C.vaddy_event{}
	for {
		if (C.vaddy_stopped() != 0 || stdatomic.load_i64(&s.pool.stopping) != 0) && !s.draining {
			s.draining = true
			s.drain_started = mono_ms()
			s.watch(s.http_fd, 0) or {}
			if s.http_fd >= 0 {
				C.vaddy_close(s.http_fd)
				s.http_fd = -1
			}
			if s.https_fd >= 0 {
				s.watch(s.https_fd, 0) or {}
				C.vaddy_close(s.https_fd)
				s.https_fd = -1
			}
			if s.control_fd >= 0 { s.drain_incoming() }
			for _, mut c in s.clients.clone() { if !c.have_request { s.close_client(mut c) } }
		}
		if s.draining && s.clients.len == 0 { break }
		n := C.vaddy_wait(s.queue, &events[0], events.len, 1000)
		if n < 0 && C.vaddy_again() == 0 { return error('event queue failed') }
		for i in 0 .. if n > 0 { n } else { 0 } {
			event := events[i]
			if event.fd == s.control_fd {
				s.drain_incoming()
				continue
			}
			if event.fd == s.http_fd {
				s.accept_clients(event.fd, false)
				continue
			}
			if event.fd == s.https_fd {
				s.accept_clients(event.fd, true)
				continue
			}
			owner := s.owners[event.fd] or { continue }
			mut c := s.clients[owner] or { continue }
			s.pump(mut c, event.fd) or {
				if c.have_response || c.write_len > 0 {
					c.dead = true
				} else {
					s.respond(mut c, 502, 'Bad Gateway', 'Bad Gateway\n', '')
				}
			}
			s.update_interests(mut c) or { s.close_client(mut c) }
		}
		s.tick()
	}
}
