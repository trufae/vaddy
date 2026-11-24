module main

import os
import src.log
import sync.stdatomic
import time
import x.json2

const read_chunk_size = 16384

struct Options {
mut:
	acme_transport         AcmeTransport = acme_http @[ignore]
	config                 string                    @[xdoc: 'Config file path']
	data                   string                    @[xdoc: 'Certificate/account storage (default: XDG data/vaddy)']
	bind                   string = '::'             @[xdoc: 'Listen address (default: ::, dual IPv4/IPv6)']
	max_connections        int    = 512              @[xdoc: 'Bound active clients (default: 512)']
	workers                int    = 1                @[xdoc: 'Event-loop workers, 1..64 (default: 1)']
	max_keepalive_requests int    = 1000             @[xdoc: 'Maximum number of keepalive requests to process']
	idle_timeout           int    = 60               @[xdoc: 'Inactive connection timeout (default: 60)']
	header_timeout         int    = 15               @[xdoc: 'Header/handshake timeout (default: 15)']
	http_port              string                    @[xdoc: 'Override HTTP port (default: 80)']
	https_port             string                    @[xdoc: 'Override HTTPS port (default: 443)']
	staging                bool                      @[xdoc: 'Use Let\'s Encrypt staging CA and separate storage']
	adapter                string = 'caddyfile'      @[xdoc: 'Config adapter (caddyfile)']
	help                   bool                      @[short: h; xdoc: 'Show this help']
	version                bool                      @[short: v; xdoc: 'Show version']
}

@[heap]
struct Connection {
mut:
	file_output            FileOutput
	output                 EncodedOutput
	wire_output            Buffer
	h2                     voidptr
	h2_streams             map[int]&Connection
	h2_id                  int
	h2_parent              voidptr
	h2_state               &C.vaddy_h2_stream = C.NULL
	h2_chunked_input       bool
	h2_input_end           bool
	h2_headers_sent        bool
	h2_output_end          bool
	h2_output_frame        Framing
	runtime                ?&Runtime
	backend_generation     i64
	access_targets         []log.Target
	log_rules              []LogRule
	log_early              map[string]json2.Any
	access_logged          bool
	log_status             int
	log_started            i64
	log_size               i64
	log_bytes_read         i64
	log_empty_content_type bool
	log_response_fields    []Field
	remote_port            string
	fd                     int
	counted                bool
	backend                int = -1
	backend_tls            voidptr
	backend_handshake      bool
	backend_handshake_want int = 2
	backend_read_want      int = 1
	backend_write_want     int = 2
	backend_stop_write     bool
	backend_write_len      int
	backend_name           string
	connecting             bool
	ip                     string
	tls                    voidptr
	handshake              bool
	handshake_want         int = 1
	read_want              int = 1
	write_want             int = 2
	write_len              int
	request_buffer         Buffer
	response_buffer        Buffer
	to_backend             Buffer
	to_client              Buffer
	request                Message
	response               Message
	have_request           bool
	have_response          bool
	close_after            bool
	tunnel                 bool
	dead                   bool
	local                  bool
	local_body             string
	site                   int = -1
	response_headers       []HeaderEdit
	header_values          HeaderValues
	requests               int
	last_activity          i64
	started                i64
}

struct Server {
mut:
	// Reads append only the bytes returned by the socket to a connection buffer.
	// Each reactor can reuse the same scratch space across all its connections.
	read_scratch  []u8 = []u8{len: buffer_limit}
	header_scratch Buffer
	runtime_store ?&RuntimeStore
	retired       []&Runtime
	run_id        string
	cfg           Config
	opts          Options
	queue         int
	http_fd       int         = -1
	pool          &WorkerPool = &WorkerPool{}
	control_fd    int         = -1
	incoming      chan IncomingConnection
	next_worker   int
	https_fd      int = -1
	ctx           voidptr
	cert_file     string
	key_file      string
	cert_stamp    string
	clients       map[int]&Connection
	owners        map[int]int
	watches       map[int]int
	access_logs   map[string]&log.Writer
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
	if !isnil(c.backend_tls) { C.vaddy_tls_free(c.backend_tls) }
	c.backend_tls = voidptr(0)
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
	c.close_file()
	c.close_encoder()
	if !isnil(c.h2) {
		for id in c.h2_streams.keys() { s.close_h2_stream(mut c, id) }
		C.vaddy_h2_free(c.h2)
		c.h2 = voidptr(0)
	}
	c.log_access()
	release_runtime(mut c)
	s.close_backend(mut c)
	s.watch(c.fd, 0) or {}
	s.watches.delete(c.fd)
	if !isnil(c.tls) {
		C.vaddy_tls_free(c.tls)
		c.tls = voidptr(0)
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
	c.close_file()
	s.close_backend(mut c)
	c.to_client.clear()
	c.to_backend.clear()
	c.log_status = code
	mut response_body := body
	mut header := Buffer{}
	c.close_after = !keepalive || c.request.close || s.draining || c.requests >= s.opts.max_keepalive_requests - 1 || c.request.expect || c.request.frame.kind == .chunked || c.request.frame.remaining > 262144
	connection := if c.close_after { 'Connection: close\r\n' } else { '' }
	content := if content_type == '' { '' } else { 'Content-Type: ${content_type}\r\n' }
	length := if code in [204, 304] || (keepalive && c.request.method == 'HEAD' && body == '') {
		''
	} else {
		'Content-Length: ${body.len}\r\n'
	}
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
	if c.access_targets.len > 0 {
		c.log_response_fields = buffer_header_fields(header).filter(it.lower !in [
			'content-length',
			'connection',
		])
	}
	c.log_size = response_body.len
	c.to_client.add(header.bytes())
	c.local_body = if c.request.method == 'HEAD' { '' } else { response_body }
	c.local = true
	c.have_response = true
	c.response = Message{ frame: Framing{ remaining: c.local_body.len, done: c.local_body == '' } }
	c.pump_local_body()
}

fn (mut s Server) accept_clients(listener int, tls bool) {
	if s.accept_retry > 0 { return }
	for _ in 0 .. 32 {
		if s.active_clients() >= s.opts.max_connections {
			s.pause_accepts()
			break
		}
		mut ip := [128]char{}
		mut ip_len := 0
		fd := C.vaddy_accept(listener, &ip[0], ip.len, &ip_len)
		if fd < 0 {
			// Exhausted descriptors must not leave a readable listener spinning the reactor.
			if C.vaddy_again() == 0 { s.pause_accepts() }
			break
		}
		if tls && isnil(s.ctx) {
			C.vaddy_close(fd)
			continue
		}
		now := mono_ms()
		mut c := &Connection{ fd: fd, remote_port: C.vaddy_peer_port(fd).str(), ip: copy_platform_string(&ip[0], ip_len), last_activity: now, started: now }
		if tls {
			c.tls = C.vaddy_tls_new(s.ctx, fd)
			if isnil(c.tls) {
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

// Site and route directives belong to the immutable runtime configuration.
fn combined_directives[T](site []T, route []T) []T {
	if route.len == 0 { return site }
	if site.len == 0 { return route }
	mut combined := site.clone()
	combined << route
	return combined
}

fn (mut s Server) begin_request(mut c Connection) !bool {
	input := c.request_buffer.bytes()
	end := header_end(input)
	if end < 0 {
		if input.len >= header_limit {
			s.respond(mut c, 431, 'Request Header Fields Too Large', 'Headers too large\n', '')
		}
		return false
	}
	c.request = parse_message_reuse(input[..end + 4].bytestr(), true, false, c.request.fields) or {
		s.respond(mut c, 400, 'Bad Request', 'Bad Request\n', '')
		return false
	}
	c.request_buffer.skip(end + 4)
	m := &c.request
	c.have_request = true
	c.access_logged = false
	c.log_status = 0
	c.log_started = time.sys_mono_now()
	c.log_size = 0
	c.log_empty_content_type = false
	c.log_bytes_read = 0
	c.log_response_fields = []Field{}
	mut cfg := s.cfg
	mut backends := s.backends
	mut logs := s.access_logs
	mut generation := i64(0)
	if mut store := s.runtime_store {
		runtime := store.acquire()
		c.runtime = runtime
		cfg = runtime.cfg
		backends = runtime.backends
		logs = runtime.logs
		generation = runtime.id
	}
	site_host := m.host_name.trim_right('.').to_lower()
	c.site = cfg.site_index(site_host, !isnil(c.tls))
	if c.site < 0 {
		s.respond(mut c, 421, 'Misdirected Request', 'Unknown host\n', '')
		return false
	}
	site := &cfg.sites[c.site]
	c.response_headers = site.response_headers
	c.header_values = HeaderValues{ uri: m.uri, method: m.method, fields: m.fields, host: m.host_name, hostport: m.host, port: m.host_port, scheme: if isnil(c.tls) {
		'http'
	} else {
		'https'
	}, remote_host: c.ip, remote_port: c.remote_port }
	c.log_early = map[string]json2.Any{}
	c.log_rules = site.log_rules
	c.capture_early_logs(site.log_rules)
	c.access_targets = access_targets(cfg, site, logs, c.log_rules, c.header_values)
	if isnil(c.tls) {
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
			https_port := if cfg.https_port == 443 { '' } else { ':${cfg.https_port}' }
			authority := if site_host.contains(':') { '[${site_host}]' } else { site_host }
			s.respond(mut c, 308, 'Permanent Redirect', '', 'Location: https://${authority}${https_port}${m.uri}\r\n')
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
	if route.log_rules.len > 0 {
		c.capture_early_logs(route.log_rules)
		c.log_rules = combined_directives(site.log_rules, route.log_rules)
		c.access_targets = access_targets(cfg, site, logs, c.log_rules, c.header_values)
	}
	c.response_headers = combined_directives(site.response_headers, route.response_headers)
	if text := route.respond {
		body := expand_placeholders_limited(text, c.header_values, respond_body_limit) or {
			s.respond(mut c, 500, 'Internal Server Error', '', '')
			return false
		}
		s.respond_options(mut c, 200, 'OK', body, '', true, 'text/plain; charset=utf-8')
		return false
	}
	if route.redirect != '' {
		s.redirect_response(mut c, route)!
		return false
	}
	c.header_values.upstream_hostport = route.upstream.trim_string_left('https://')
	edits := combined_directives(site.request_headers, route.request_headers)
	handler_fields := if edits.any(!it.proxy) {
		mut fields := m.fields.clone()
		apply_header_edits(mut fields, edits.filter(!it.proxy), c.header_values, 0, false)!
		fields
	} else {
		m.fields
	}
	encoding := if route.encode.enabled { route.encode } else { site.encode }
	if encoding.enabled && header_edit_matches(encoding.filter, [], c.header_values, 0) {
		c.output.config = encoding
		c.output.name = accepted_encoding(handler_fields, encoding.formats)
	}
	if route.files.enabled {
		s.close_backend(mut c)
		s.serve_file(mut c, site, route, handler_fields)!
		return false
	}
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
		if !isnil(backend.ctx) {
			c.backend_tls = C.vaddy_upstream_tls(backend.ctx, c.backend, &char(backend.name.str))
			if isnil(c.backend_tls) {
				return error('cannot create upstream TLS session')
			}
			c.backend_handshake = true
			c.backend_handshake_want = 2
		}
		s.owners[c.backend] = c.fd
	}
	mut upstream_request := *m
	upstream_request.fields = handler_fields
	if c.output.name != '' && handler_fields.any(it.lower == 'if-none-match') {
		upstream_request.fields = handler_fields.clone()
		for mut field in upstream_request.fields {
			if field.lower == 'if-none-match' {
				field = Field{ ...field, value: field.value.replace('-${c.output.name}"', '"') }
			}
		}
	}
	upstream_request.host = ''
	for field in &handler_fields {
		if field.lower == 'host' { upstream_request.host = field.value }
	}
	fallback_host := route.upstream.trim_string_left('https://')
	host := if route.upstream.starts_with('https://') || upstream_request.host == '' {
		fallback_host
	} else {
		upstream_request.host
	}
	field_count := c.to_backend.request_header(upstream_request, rewrite_uri(m.uri, route.rewrite), c.ip, !isnil(c.tls), host)
	if edits.any(it.proxy) {
		edit_header_buffer(mut c.to_backend, edits.filter(it.proxy), c.header_values)!
		// Host is represented separately by Go's request type: an append replaces it.
		mut wire_fields := buffer_header_fields(c.to_backend)
		wire_hosts := wire_fields.filter(it.lower == 'host')
		wire_fields = wire_fields.filter(it.lower != 'host')
		wire_fields << Field{'Host', 'host', if wire_hosts.len > 0 && wire_hosts.last().value != '' {
			wire_hosts.last().value
		} else {
			fallback_host
		}}
		write_header_fields(mut c.to_backend, wire_fields)!
	} else {
		// Host is already normalized above. Preserve the same limits without a
		// parse/filter/serialize round trip when there are no proxy header edits.
		if field_count > 128 { return error('too many output headers') }
		if c.to_backend.len() > header_limit { return error('edited headers too large') }
	}

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

fn (mut s Server) write_response_header(mut c Connection, m &Message, close bool) ! {
	s.header_scratch.clear()
	if c.response_headers.len == 0 {
		s.header_scratch.response_header(m, [], close)
	} else {
		mut fields := []Field{cap: m.fields.len + 3}
		for field in &m.fields {
			if !hop_header(field.lower, m.connection) { fields << *field }
		}
		for field in m.response_framing_fields(close) {
			if field.name != '' { fields << field }
		}
		edited := response_fields_with_edits(mut fields, c.response_headers, c.header_values, m.status, false)!
		s.header_scratch.append_header_fields(m.start, edited)!
	}
	if c.access_targets.len > 0 && (m.status >= 200 || m.status == 101) {
		c.log_response_fields = buffer_header_fields(s.header_scratch).filter(it.lower !in ['connection', 'transfer-encoding'])
	}
	if c.to_client.room() < s.header_scratch.len() { return error('response header output exceeds buffer') }
	c.to_client.add(s.header_scratch.bytes())
}

fn (mut s Server) consume_response(mut c Connection) ! {
	for !c.have_response {
		input := c.response_buffer.bytes()
		end := header_end(input)
		if end < 0 {
			if input.len >= header_limit { return error('upstream headers too large') }
			return
		}
		if c.to_client.room() < end + 128 { return }
		mut m := parse_message_reuse(input[..end + 4].bytestr(), false, c.request.method == 'HEAD', c.response.fields)!
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
		if !c.tunnel && isnil(c.output.codec) {
			c.log_size = c.response.frame.body_bytes
		}
		if n == data.len {
			c.response_buffer.transfer_to(mut c.to_client)
		} else {
			c.to_client.add(data[..n])
			c.response_buffer.skip(n)
		}
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
	if !c.output.done || c.wire_output.len() > 0 { return }
	if c.h2_id != 0 {
		if c.have_response && c.response.frame.done && c.to_client.len() == 0 && c.h2_headers_sent && !c.h2_output_end {
			C.vaddy_h2_end(c.h2_parent, c.h2_state)
			c.h2_output_end = true
			s.close_backend(mut c)
		}
		return
	}
	if c.local && !c.close_after && !c.request.frame.done { return }
	if !c.have_response || !c.response.frame.done || c.to_client.len() > 0 { return }
	c.log_access()
	c.close_encoder()
	c.output = EncodedOutput{}
	if c.close_after || s.draining {
		c.dead = true
		return
	}
	if c.response.close { s.close_backend(mut c) }
	c.requests++
	release_runtime(mut c)
	c.have_request = false
	c.local = false
	c.access_targets = []log.Target{}
	c.log_rules = []LogRule{}
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
			if C.vaddy_tls_is_h2(c.tls) != 0 {
				c.h2 = C.vaddy_h2_new(s.opts.max_keepalive_requests)
				if isnil(c.h2) { return error('cannot create HTTP/2 session') }
			}
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
	if !isnil(c.h2) {
		s.pump_h2(mut c, event_fd)!
		return
	}
	if c.connecting && event_fd == c.backend {
		// A queued event can refer to a descriptor closed and reused by another
		// HTTP/2 stream; SO_ERROR == 0 alone does not prove connect completed.
		connected := C.vaddy_connected(c.backend)
		if connected < 0 { return error('upstream connect failed') }
		c.connecting = connected != 0
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
	// Drain each ready input until EAGAIN, then wait for another readiness event.
	// OpenSSL may have records buffered even when the kernel socket is no longer
	// readable, so those records must also be allowed to drive the client read.
	mut client_readable := c.h2_id == 0 && (event_fd == c.fd || (!isnil(c.tls) && C.vaddy_tls_has_pending(c.tls) != 0))
	mut backend_readable := event_fd == c.backend || (!isnil(c.backend_tls) && C.vaddy_tls_has_pending(c.backend_tls) != 0)
	for _ in 0 .. 8 {
		mut progress := false
		body_remaining := c.response.frame.remaining
		c.pump_local_body()
		c.pump_file()!
		if body_remaining != c.response.frame.remaining { progress = true }
		before_output := c.to_client.len()
		c.prepare_output()!
		if before_output != c.to_client.len() { progress = true }
		if c.h2_id != 0 { h2_egress(mut c)! }
		if c.h2_id == 0 && c.wire_output.len() > 0 {
			data := c.wire_output.bytes()
			mut n := 0
			if !isnil(c.tls) {
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
				n = int(C.vaddy_send(c.fd, data.data, u64(data.len), 0))
				if n < 0 && C.vaddy_again() == 0 {
					c.dead = true
					return
				}
			}
			if n > 0 {
				c.wire_output.skip(n)
				progress = true
			}
		}
		s.finish_request(mut c)!
		if c.dead { return }
		if !c.local && c.backend >= 0 && !c.connecting && !c.backend_handshake && !c.backend_stop_write && c.to_backend.len() > 0 {
			data := c.to_backend.bytes()
			mut n := 0
			if !isnil(c.backend_tls) {
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
				n = int(C.vaddy_send(c.backend, data.data, u64(data.len), 0))
				if n < 0 && C.vaddy_again() == 0 { return error('upstream write failed') }
			}
			if n > 0 {
				c.to_backend.skip(n)
				progress = true
			}
		}
		if backend_readable && !c.local && c.have_request && c.backend >= 0 && !c.connecting && !c.backend_handshake && !(c.backend_write_len > 0 && c.backend_write_want == 1) && !c.response.frame.done && c.response_buffer.room() > 0 && c.to_client.room() >= read_chunk_size {
			// Read at most one output window and keep applying backpressure.
			limit := if c.response_buffer.room() < c.to_client.room() {
				c.response_buffer.room()
			} else {
				c.to_client.room()
			}
			mut n := 0
			if !isnil(c.backend_tls) {
				n = C.vaddy_tls_read(c.backend_tls, s.read_scratch.data, limit)
				if n <= 0 {
					err := C.vaddy_tls_error(c.backend_tls, n)
					backend_readable = false
					if err == 6 {
						s.backend_eof(mut c)!
					} else if err in [2, 3] {
						c.backend_read_want = if err == 2 { 1 } else { 2 }
					} else {
						return error('upstream TLS read failed')
					}
				} else {
					c.backend_read_want = 1
				}
			} else {
				n = int(C.vaddy_recv(c.backend, s.read_scratch.data, u64(limit), 0))
				if n < 0 { backend_readable = false }
				if n < 0 && C.vaddy_again() == 0 { return error('upstream read failed') }
				if n == 0 { s.backend_eof(mut c)! }
			}
			if n > 0 {
				c.response_buffer.add(s.read_scratch[..n])
				progress = true
			}
		}
		if !c.local && c.response_buffer.len() > 0 { s.consume_response(mut c)! }
		if !c.local && !c.have_request && c.request_buffer.len() > 0 { s.consume_request(mut c)! }
		if c.have_request && !c.request.frame.done && c.request_buffer.len() > 0 && c.to_backend.room() > 0 {
			s.consume_request(mut c)!
		}
		can_read := (!c.local || !c.close_after) && (!c.have_request || (!c.request.frame.done && (!c.have_response || c.tunnel || c.local))) && c.request_buffer.room() >= read_chunk_size && c.to_backend.room() >= read_chunk_size
		if client_readable && can_read && !(c.write_len > 0 && c.write_want == 1) {
			mut n := 0
			if !isnil(c.tls) {
				n = C.vaddy_tls_read(c.tls, s.read_scratch.data, read_chunk_size)
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
				n = int(C.vaddy_recv(c.fd, s.read_scratch.data, u64(read_chunk_size), 0))
				if n < 0 { client_readable = false }
				if n == 0 || (n < 0 && C.vaddy_again() == 0) {
					c.dead = true
					return
				}
			}
			if n > 0 {
				if !c.have_request && c.request_buffer.len() == 0 { c.started = mono_ms() }
				c.request_buffer.add(s.read_scratch[..n])
				s.consume_request(mut c) or { s.respond(mut c, 400, 'Bad Request', 'Bad Request\n', '') }
				progress = true
			}
		}
		if !progress { break }
		c.last_activity = mono_ms()
	}
	// Keep record storage across writes during a response. At idle, OpenSSL
	// can free it if neither direction has TLS records still pending.
	if c.h2_id == 0 && !isnil(c.tls) && (!c.have_request || c.tunnel)
		&& c.request_buffer.len() == 0 && c.to_client.len() == 0 && c.wire_output.len() == 0 {
		C.vaddy_tls_free_buffers(c.tls)
	}
}

fn (mut s Server) update_interests(mut c Connection) ! {
	if c.dead {
		s.close_client(mut c)
		return
	}
	if !isnil(c.h2) {
		s.update_h2_interests(mut c)!
		return
	}
	mut flags := 0
	if c.handshake {
		flags = c.handshake_want
	} else {
		if c.has_output_work() { flags |= c.write_want }
		if (!c.local || !c.close_after) && (!c.have_request || (!c.request.frame.done && (!c.have_response || c.tunnel || c.local))) && c.request_buffer.room() >= read_chunk_size && c.to_backend.room() >= read_chunk_size {
			flags |= c.read_want
		}
	}
	s.watch(c.fd, flags)!
	s.update_backend_interests(mut c)!
}

fn (mut s Server) update_backend_interests(mut c Connection) ! {
	if c.backend >= 0 {
		mut back := 0
		if c.connecting {
			back = 2
		} else if c.backend_handshake {
			back = c.backend_handshake_want
		} else {
			if !c.backend_stop_write && c.to_backend.len() > 0 { back |= c.backend_write_want }
			if c.have_request && !c.response.frame.done && c.response_buffer.room() > 0 && c.to_client.room() >= read_chunk_size {
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
	if isnil(ctx) {
		eprintln('vaddy: cannot load TLS certificate ${cert}')
		return
	}
	old := s.ctx
	s.ctx = ctx
	s.cert_stamp = stamp
	if !isnil(old) { C.vaddy_tls_ctx_free(old) }
	eprintln('vaddy: loaded TLS certificate for ${s.cfg.domains().join(', ')}')
}

fn (mut s Server) tick() {
	now := mono_ms()
	if now - s.last_tick < 1000 { return }
	s.last_tick = now
	if !s.draining {
		s.reload_certificate()
		if s.runtime_store != none && s.control_fd < 0 {
			s.check_reload()
			s.reap_runtimes()
		}
	}
	for _, mut c in s.clients.clone() {
		if !isnil(c.h2) {
			for _, stream in c.h2_streams {
				if now - stream.last_activity > i64(s.opts.idle_timeout) * 1000 || ((stream.connecting || stream.backend_handshake || !stream.have_response) && now - stream.started > i64(s.opts.header_timeout) * 1000) {
					C.vaddy_h2_reset(c.h2, stream.h2_id, 8)
				}
			}
			s.pump_h2(mut c, -1) or { c.dead = true }
			s.update_interests(mut c) or { c.dead = true }
			if c.dead {
				s.close_client(mut c)
				continue
			}
		}
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
	store := new_runtime_store(cfg)!
	s.runtime_store = store
	s.backends = store.current.backends.clone()
	s.access_logs = store.current.logs.clone()
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
		if site.tls_mode == 'manual' && isnil(s.ctx) {
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
		if !isnil(s.ctx) { C.vaddy_tls_ctx_free(s.ctx) }
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
			for _, mut c in s.clients.clone() {
				if !isnil(c.h2) {
					C.vaddy_h2_drain(c.h2)
					s.pump_h2(mut c, -1) or { c.dead = true }
					s.update_interests(mut c) or { s.close_client(mut c) }
				} else if !c.have_request {
					s.close_client(mut c)
				}
			}
		}
		if s.draining && s.clients.len == 0 { break }
		n := C.vaddy_wait(s.queue, &events[0], events.len, 1000)
		if n < 0 && C.vaddy_again() == 0 { return error('event queue failed') }
		ready := if n > 0 { n } else { 0 }
		for i in 0 .. ready {
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
				if !isnil(c.h2) || c.have_response || c.write_len > 0 {
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
