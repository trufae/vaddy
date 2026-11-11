module main

import sync.stdatomic

// HTTP/2 framing and HPACK live in nghttp2. Each stream uses the same bounded
// request/proxy state machine as HTTP/1; all streams stay on their socket's worker.
fn h2_request_headers(stream &C.vaddy_h2_stream) !string {
	fields := unsafe { stream.headers.vbytes(stream.header_len) }.bytestr().split('\x00')
	mut method := ''
	mut path := ''
	mut authority := ''
	mut host := ''
	mut headers := ''
	mut cookies := []string{}
	mut has_length := false
	for i := 0; i + 1 < fields.len; i += 2 {
		name, value := fields[i], fields[i + 1]
		if invalid_controls(value, true) { return error('invalid HTTP/2 header value') }
		match name {
			':method' { method = value }
			':path' { path = value }
			':authority' { authority = value }
			':scheme' {}
			'host' { host = value }
			'cookie' { cookies << value }
			else {
				if !is_token(name) || name.starts_with(':') { return error('invalid HTTP/2 header name') }
				if name == 'content-length' { has_length = true }
				headers += '${name}: ${value}\r\n'
			}
		}
	}
	if method == 'CONNECT' { return error('CONNECT is unsupported') }
	if authority == '' { authority = host }
	if host != '' && authority != host { return error('Host and :authority disagree') }
	if cookies.len > 0 { headers += 'Cookie: ${cookies.join('; ')}\r\n' }
	if !has_length && stream.remote_end == 0 { headers += 'Transfer-Encoding: chunked\r\n' }
	return '${method} ${path} HTTP/1.1\r\nHost: ${authority}\r\n${headers}\r\n'
}

// Decode framed body bytes without buffering a whole chunk or response. Also
// used by encoders: HTTP/1 chunk markers must never become HTTP/2 DATA payload.
fn (mut frame Framing) consume_decoded(data []u8, mut output Buffer) !int {
	mut used := 0
	for used < data.len && !frame.done {
		if frame.kind != .chunked || frame.stage == 1 {
			mut size := data.len - used
			if size > output.room() { size = output.room() }
			if frame.kind in [.length, .chunked] && frame.remaining < size { size = int(frame.remaining) }
			if size == 0 { break }
			n := frame.consume(data[used..used + size])!
			output.add(data[used..used + n])
			used += n
		} else {
			used += frame.consume(data[used..used + 1])!
		}
	}
	return used
}

fn (mut s Server) close_h2_stream(mut parent Connection, id int) {
	mut stream := parent.h2_streams[id] or { return }
	s.log_access(mut stream, stream.h2_output_end)
	release_runtime(mut stream)
	s.close_backend(mut stream)
	if stream.counted {
		stdatomic.sub_i64(&s.pool.active_streams, 1)
		stream.counted = false
	}
	stream.dead = true
	parent.h2_streams.delete(id)
}

fn (mut s Server) h2_open_stream(mut parent Connection, state &C.vaddy_h2_stream) ! {
	if stdatomic.add_i64(&s.pool.active_streams, 1) > s.opts.max_connections {
		stdatomic.sub_i64(&s.pool.active_streams, 1)
		C.vaddy_h2_reset(parent.h2, state.id, 7) // REFUSED_STREAM: safe for clients to retry.
		return
	}
	now := mono_ms()
	mut stream := &Connection{
		fd: parent.fd, tls: parent.tls, ip: parent.ip, remote_port: parent.remote_port
		h2_id: state.id, h2_parent: parent.h2, h2_state: state, counted: true
		started: now, last_activity: now
	}
	parent.h2_streams[state.id] = stream
	parent.requests++
	raw := h2_request_headers(state) or {
		C.vaddy_h2_reset(parent.h2, state.id, 1)
		return
	}
	stream.request_buffer.write_string(raw)
	s.consume_request(mut stream) or { s.respond(mut stream, 400, 'Bad Request', 'Bad Request\n', '') }
	stream.h2_chunked_input = stream.request.frame.kind == .chunked
}

fn h2_ingress(mut c Connection) ! {
	state := c.h2_state
	if c.h2_input_end || state.closed != 0 { return }
	mut scratch := [16384]u8{}
	room := c.request_buffer.room() - 32
	if room <= 0 { return }
	limit := if room < scratch.len { room } else { scratch.len }
	if state.input_len > 0 {
		n := C.vaddy_h2_take(c.h2_parent, state, &scratch[0], limit)
		if n < 0 { return error('HTTP/2 flow control failure') }
		if c.h2_chunked_input { c.request_buffer.write_string('${n:x}\r\n') }
		c.request_buffer.add(scratch[..n])
		if c.h2_chunked_input { c.request_buffer.write_string('\r\n') }
	}
	if state.input_len == 0 && state.remote_end != 0 {
		if c.h2_chunked_input { c.request_buffer.write_string('0\r\n\r\n') }
		c.h2_input_end = true
	}
}

fn h2_egress(mut c Connection) ! {
	if c.h2_state.closed != 0 || c.h2_output_end { return }
	for !c.h2_headers_sent {
		raw := c.to_client.bytes().bytestr()
		end := raw.index('\r\n\r\n') or { return }
		message := parse_message_reuse(raw[..end + 4], false, c.request.method == 'HEAD', [])!
		if message.status == 101 { return error('HTTP/1 upgrade cannot be sent on HTTP/2') }
		mut fields := ':status\x00${message.status}\x00'
		for field in message.fields {
			if hop_header(field.lower, message.connection) || field.lower == 'te' { continue }
			fields += '${field.lower}\x00${field.value}\x00'
		}
		if C.vaddy_h2_response(c.h2_parent, c.h2_state, fields.str, fields.len, int(message.status < 200)) != 0 { return error('cannot submit HTTP/2 headers') }
		c.to_client.skip(end + 4)
		if message.status >= 200 {
			c.h2_headers_sent = true
			c.h2_output_frame = message.frame
		}
	}
	if c.to_client.len() > 0 {
		room := buffer_limit - c.h2_state.output_len
		if room == 0 { return }
		// Decode at most one available output window. Input may contain more
		// chunk framing than payload, so limit the decoder's output explicitly.
		mut decoded := Buffer{}
		data := c.to_client.bytes()
		limit := if data.len < room { data.len } else { room }
		n := c.h2_output_frame.consume_decoded(data[..limit], mut decoded)!
		if C.vaddy_h2_push(c.h2_parent, c.h2_state, decoded.bytes().data, decoded.len()) != 0 { return error('cannot queue HTTP/2 data') }
		c.to_client.skip(n)
	}
}

fn (mut s Server) pump_h2(mut parent Connection, event_fd int) ! {
	if s.draining { C.vaddy_h2_drain(parent.h2) }
	mut readable := event_fd == parent.fd || C.vaddy_tls_has_pending(parent.tls) != 0
	mut scratch := [16384]u8{}
	for _ in 0 .. 16 {
		mut progress := false
		if readable && !(parent.write_len > 0 && parent.write_want == 1) {
			n := C.vaddy_tls_read(parent.tls, &scratch[0], scratch.len)
			if n > 0 {
				if C.vaddy_h2_receive(parent.h2, &scratch[0], n, mono_ms()) != n { return error('invalid HTTP/2 input') }
				progress = true
				parent.read_want = 1
			} else {
				readable = false
				err := C.vaddy_tls_error(parent.tls, n)
				if err !in [2, 3] { parent.dead = true; return }
				parent.read_want = if err == 2 { 1 } else { 2 }
			}
		}
		mut state := C.vaddy_h2_first(parent.h2)
		for state != unsafe { nil } {
			next := state.next
			if state.closed != 0 {
				s.close_h2_stream(mut parent, state.id)
				C.vaddy_h2_remove(parent.h2, state)
			} else if state.ready == 1 {
				state.ready = 2
				s.h2_open_stream(mut parent, state)!
				progress = true
			}
			state = next
		}
		for _, mut stream in parent.h2_streams {
			if stream.h2_state.closed != 0 { continue }
			before := stream.to_client.len() + stream.to_backend.len() + stream.request_buffer.len() + stream.response_buffer.len() + stream.h2_state.input_len + stream.h2_state.output_len
			h2_ingress(mut stream) or { C.vaddy_h2_reset(parent.h2, stream.h2_id, 1); continue }
			s.pump(mut stream, event_fd) or {
				eprintln('vaddy: HTTP/2 stream ${stream.h2_id}: ${err}')
				if stream.have_response { C.vaddy_h2_reset(parent.h2, stream.h2_id, 2) }
				else { s.respond(mut stream, 502, 'Bad Gateway', 'Bad Gateway\n', '') }
			}
			if stream.dead { C.vaddy_h2_reset(parent.h2, stream.h2_id, 2) }
			after := stream.to_client.len() + stream.to_backend.len() + stream.request_buffer.len() + stream.response_buffer.len() + stream.h2_state.input_len + stream.h2_state.output_len
			if before != after { progress = true; stream.last_activity = mono_ms() }
		}
		if C.vaddy_h2_flush(parent.h2) != 0 { return error('HTTP/2 serialization failed') }
		length := C.vaddy_h2_wire_len(parent.h2)
		if length > 0 {
			if parent.write_len == 0 { parent.write_len = length }
			n := C.vaddy_tls_write(parent.tls, C.vaddy_h2_wire(parent.h2), parent.write_len)
			if n > 0 {
				C.vaddy_h2_wire_skip(parent.h2, n)
				parent.write_len = 0
				parent.write_want = 2
				progress = true
			} else {
				err := C.vaddy_tls_error(parent.tls, n)
				if err !in [2, 3] { parent.dead = true; return }
				parent.write_want = if err == 2 { 1 } else { 2 }
			}
		}
		if C.vaddy_h2_finished(parent.h2) != 0 { parent.dead = true; return }
		if !progress { break }
		parent.last_activity = mono_ms()
	}
}

fn (mut s Server) update_h2_interests(mut parent Connection) ! {
	mut flags := parent.read_want
	if C.vaddy_h2_wants_write(parent.h2) != 0 { flags |= parent.write_want }
	s.watch(parent.fd, flags)!
	for _, mut stream in parent.h2_streams { s.update_backend_interests(mut stream)! }
}
