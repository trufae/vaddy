module main

import strconv
import strings

const header_limit = 16384
const buffer_limit = 32768

struct Field {
	name  string
	lower string
	value string
}

struct Message {
mut:
	method     string
	uri        string
	status     int
	start      string
	fields     []Field
	host       string
	close      bool
	upgrade    bool
	expect     bool
	frame      Framing
	connection []string
}

enum BodyKind {
	none
	length
	chunked
	eof
	tunnel
}

struct Framing {
mut:
	kind          BodyKind
	body_bytes i64
	remaining     i64
	stage         int
	line          string
	trailer_bytes int
	done          bool
}

fn is_token(s string) bool {
	if s == '' { return false }
	for i in 0 .. s.len {
		c := s[i]
		if c.is_alnum() { continue }
		match c {
			`!`, `#`, `$`, `%`, `&`, `'`, `*`, `+`, `-`, `.`, `^`, `_`, 0x60, `|`, `~` {}
			else { return false }
		}
	}
	return true
}

fn all_digits(s string) bool {
	if s == '' { return false }
	for i in 0 .. s.len { if !s[i].is_digit() { return false } }
	return true
}

fn invalid_controls(s string, allow_tab bool) bool {
	for i in 0 .. s.len {
		if (s[i] < 32 && !(allow_tab && s[i] == 9)) || s[i] == 127 { return true }
	}
	return false
}

// The reactor supplies its previous header array, exclusively owned by this
// connection, to retain capacity across keep-alive requests.
fn parse_message_reuse(raw string, request bool, head bool, fields []Field) !Message {
	if raw.len > header_limit || !raw.ends_with('\r\n\r\n') {
		return error('invalid header size or terminator')
	}
	first := raw.index('\r\n') or { return error('missing start line') }
	start := raw[..first]
	if invalid_controls(start, false) { return error('invalid start line characters') }
	mut m := Message{ start: start, fields: fields }
	// Drop old string references as well as length, so a large header followed by
	// small requests does not retain the old values in unused array capacity.
	for i in 0 .. m.fields.len { m.fields[i] = Field{} }
	m.fields.clear()
	space := start.index(' ') or { return error('invalid start line') }
	word := start[..space]
	rest := start[space + 1..]
	if request {
		separator := rest.index(' ') or { return error('invalid request line') }
		uri := rest[..separator]
		version := rest[separator + 1..]
		if !is_token(word) || version !in ['HTTP/1.1', 'HTTP/1.0'] {
			return error('invalid request line')
		}
		if !uri.starts_with('/') { return error('only origin-form request targets are supported') }
		for i in 0 .. uri.len {
			c := uri[i]
			if c <= 32 || c == 127 || c == `#` { return error('invalid request target') }
			if c == `%` && (i + 2 >= uri.len || !uri[i + 1].is_hex_digit() || !uri[i + 2].is_hex_digit()) {
				return error('invalid URI escape')
			}
		}
		m.method = word
		m.uri = uri
		m.close = version == 'HTTP/1.0'
	} else {
		status := rest.all_before(' ')
		if word !in ['HTTP/1.1', 'HTTP/1.0'] || status.len != 3 || !all_digits(status) {
			return error('invalid response line')
		}
		m.status = status.int()
		if m.status < 100 || m.status > 599 { return error('invalid response status') }
		m.close = word == 'HTTP/1.0'
	}
	mut length := i64(-1)
	mut te := false
	mut host_seen := false
	mut upgrade := ''
	mut position := first + 2
	mut count := 0
	for position < raw.len - 2 {
		end := raw.index_after('\r\n', position) or { return error('malformed header line') }
		count++
		if count > 128 { return error('too many headers') }
		idx := raw.index_after(':', position) or { return error('malformed header') }
		if idx >= end { return error('malformed header') }
		name := raw[position..idx]
		mut value_start := idx + 1
		mut value_end := end
		for value_start < value_end && raw[value_start] in [u8(` `), `\t`] { value_start++ }
		for value_end > value_start && raw[value_end - 1] in [u8(` `), `\t`] { value_end-- }
		value := raw[value_start..value_end]
		position = end + 2
		if !is_token(name) || invalid_controls(value, true) {
			return error('invalid header characters')
		}
		key := name.to_lower_ascii() // is_token above guarantees ASCII.
		match key {
			'content-length' {
				if length >= 0 || !all_digits(value) {
					return error('ambiguous content-length')
				}
				digits := value.trim_left('0')
				if digits.len > 19 || (digits.len == 19 && digits > '9223372036854775807') {
					return error('content-length overflow')
				}
				length = strconv.parse_int(value, 10, 64)!
				if length < 0 { return error('negative content-length') }
			}
			'transfer-encoding' {
				if te || value.to_lower() != 'chunked' {
					return error('unsupported transfer-encoding')
				}
				te = true
			}
			'host' {
				if host_seen || value == '' || invalid_controls(value, false) || value.contains(' ') || value.contains('@') || value.contains('/') || value.contains('\\') {
					return error('invalid host')
				}
				host_seen = true
				m.host = value
				if request {
					host_name := value.all_before(':')
					if !valid_host(host_name.trim_right('.')) {
						return error('invalid host name')
					}
					if host_name.len != value.len { port_value(value[host_name.len + 1..])! }
				}
			}
			'connection' {
				for item in value.to_lower().split(',') {
					token := item.trim_space()
					if !is_token(token) || token in ['host', 'content-length', 'transfer-encoding'] {
						return error('invalid connection option')
					}
					m.connection << token
				}
			}
			'upgrade' { upgrade = value.to_lower() }
			'expect' {
				if request && value.to_lower() != '100-continue' {
					return error('unsupported expectation')
				}
				m.expect = request
			}
			else {}
		}
		m.fields << Field{name, key, value}
	}
	if request && !host_seen { return error('missing Host header') }
	if te && length >= 0 { return error('both transfer-encoding and content-length') }
	if 'close' in m.connection { m.close = true }
	m.upgrade = upgrade == 'websocket' && 'upgrade' in m.connection
	if !request && (head || m.status == 204 || m.status == 304 || m.status < 200) {
		m.frame = Framing{ done: true }
	} else if te {
		m.frame = Framing{ kind: .chunked }
	} else if length >= 0 {
		m.frame = Framing{ kind: .length, remaining: length, done: length == 0 }
	} else if request {
		m.frame = Framing{ done: true }
	} else {
		m.frame = Framing{ kind: .eof }
		m.close = true
	}
	return m
}

// Consume exactly one framed body, preserving any pipelined bytes for the next message.
fn (mut f Framing) consume(data []u8) !int {
	if f.done { return 0 }
	if f.kind in [.eof, .tunnel] { f.body_bytes += data.len; return data.len }
	if f.kind == .length {
		n := int(if f.remaining < data.len { f.remaining } else { data.len })
		f.remaining -= n
		f.body_bytes += n
		f.done = f.remaining == 0
		return n
	}
	if f.kind != .chunked {
		f.done = true
		return 0
	}
	mut i := 0
	for i < data.len && !f.done {
		match f.stage {
			0, 3 {
				c := data[i]
				i++
				if f.line.len >= 4096 { return error('chunk line too long') }
				f.line += c.ascii_str()
				if f.stage == 3 {
					f.trailer_bytes++
					if f.trailer_bytes > header_limit { return error('trailers too large') }
				}
				if c == `\n` {
					if !f.line.ends_with('\r\n') { return error('invalid chunk line ending') }
					line := f.line[..f.line.len - 2]
					if f.stage == 0 {
						size := line.all_before(';')
						if size == '' || size.len > 15 || size.bytes().any(!it.is_hex_digit()) || line.bytes().any(it < 32 || it == 127) {
							return error('invalid chunk size')
						}
						f.remaining = strconv.parse_int(size, 16, 64)!
						f.stage = if f.remaining == 0 { 3 } else { 1 }
					} else if line == '' {
						f.done = true
					} else {
						colon := line.index(':') or { return error('invalid trailer') }
						if !is_token(line[..colon]) || line[..colon].to_lower() in [
							'host',
							'content-length',
							'transfer-encoding',
							'connection',
							'trailer',
						] || line[colon + 1..].bytes().any((it < 32 && it != 9) || it == 127) {
							return error('invalid trailer')
						}
					}
					f.line = ''
				}
			}
			1 {
				n := int(if f.remaining < data.len - i { f.remaining } else { data.len - i })
				i += n
				f.body_bytes += n
				f.remaining -= n
				if f.remaining == 0 {
					f.stage = 2
					f.remaining = 2
				}
			}
			2 {
				expected := if f.remaining == 2 { u8(`\r`) } else { u8(`\n`) }
				if data[i] != expected { return error('invalid chunk data terminator') }
				i++
				f.remaining--
				if f.remaining == 0 { f.stage = 0 }
			}
			else { return error('invalid chunk state') }
		}
	}
	return i
}

fn hop_header(name string, connection []string) bool {
	return name in ['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
		'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade'] || name in connection
}

// Return the serialized field count so callers can enforce output limits
// without parsing their own freshly written headers again.
fn (mut b Buffer) request_header(m Message, uri string, ip string, tls bool, host string) int {
	mut count := 3 // X-Forwarded-For, X-Forwarded-Host, X-Forwarded-Proto
	b.write_string(m.method)
	b.write_string(' ')
	b.write_string(uri)
	b.write_string(' HTTP/1.1\r\n')
	for field in m.fields {
		key := field.lower
		if hop_header(key, m.connection) || key in ['x-forwarded-for', 'x-forwarded-host',
			'x-forwarded-proto', 'expect'] {
			continue
		}
		b.write_string(field.name)
		b.write_string(': ')
		b.write_string(if key == 'host' && host != '' { host } else { field.value })
		b.write_string('\r\n')
		count++
	}
	if m.frame.kind == .chunked { b.write_string('Transfer-Encoding: chunked\r\n'); count++ }
	if m.upgrade { b.write_string('Connection: Upgrade\r\nUpgrade: websocket\r\n'); count += 2 }
	proto := if tls { 'https' } else { 'http' }
	b.write_string('X-Forwarded-For: ')
	b.write_string(ip)
	b.write_string('\r\nX-Forwarded-Host: ')
	b.write_string(m.host)
	b.write_string('\r\nX-Forwarded-Proto: ')
	b.write_string(proto)
	b.write_string('\r\n\r\n')
	return count
}

fn (mut b Buffer) response_header(m Message, remove []string, close bool) {
	b.write_string(m.start)
	b.write_string('\r\n')
	for field in m.fields {
		key := field.lower
		if key in remove || hop_header(key, m.connection) { continue }
		b.write_string(field.name)
		b.write_string(': ')
		b.write_string(field.value)
		b.write_string('\r\n')
	}
	if m.frame.kind == .chunked { b.write_string('Transfer-Encoding: chunked\r\n') }
	if m.status == 101 && m.upgrade {
		b.write_string('Connection: Upgrade\r\nUpgrade: websocket\r\n')
	} else if close {
		b.write_string('Connection: close\r\n')
	}
	b.write_string('\r\n')
}

struct Buffer {
mut:
	data strings.Builder
	pos  int
}

fn (b &Buffer) len() int { return b.data.len - b.pos }

fn (b &Buffer) room() int { return buffer_limit - b.len() }

fn (b &Buffer) bytes() []u8 { return b.data[b.pos..] }

fn (mut b Buffer) clear() {
	b.data.clear()
	b.pos = 0
}

fn (mut b Buffer) add(data []u8) {
	if b.pos > 0 {
		b.data.delete_many(0, b.pos)
		b.pos = 0
	}
	b.data << data
}

// Build headers directly into the reusable output queue, avoiding a temporary
// builder, string and byte-array copy for every request and response.
fn (mut b Buffer) write_string(s string) {
	if b.pos > 0 {
		b.data.delete_many(0, b.pos)
		b.pos = 0
	}
	b.data.write_string(s)
}

fn (mut b Buffer) skip(n int) {
	b.pos += n
	if b.pos == b.data.len { b.clear() }
}
