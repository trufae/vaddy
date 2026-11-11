module main

import strconv

struct EncodeConfig {
mut:
	enabled bool
	formats []string
	minimum int = 512
	gzip_level int = 5
	zstd_level int = 3
	filter HeaderEdit
	response_filter HeaderEdit
	custom_response_filter bool
}

struct EncodedOutput {
mut:
	config EncodeConfig
	name string
	headers bool
	decided bool
	done bool
	flush_pending bool
	message Message
	frame Framing
	pending Buffer
	codec &C.vaddy_encoder = unsafe { nil }
}

fn parse_encode(d Directive) !EncodeConfig {
	mut cfg := EncodeConfig{enabled: true}
	mut args := d.args[1..].clone()
	if args.len > 0 && (args[0].starts_with('/') || args[0].starts_with('@') || args[0] == '*') {
		cfg.filter = if args[0].starts_with('@') { HeaderEdit{matcher: args[0]} } else { HeaderEdit{patterns: [args[0]]} }
		args.delete(0)
	}
	for child in d.children {
		if child.args.len == 0 { return error('invalid encode option') }
		name := child.args[0]
		if name == 'minimum_length' {
			if child.children.len > 0 || child.args.len != 2 || !all_digits(child.args[1]) || child.args[1].len > 5 || child.args[1].int() > 16384 { return error('encode minimum_length must be 0..16384') }
			cfg.minimum = if child.args[1].int() == 0 { 512 } else { child.args[1].int() }
		} else if name == 'match' {
			condition := if child.args.len == 1 { child } else { Directive{args: ['match'], children: [Directive{args: child.args[1..].clone()}]} }
			edits := parse_headers(Directive{args: ['header'], children: [Directive{args: ['X-Encode-Filter', 'yes']}, condition]}, false)!
			cfg.response_filter = edits[0]
			cfg.custom_response_filter = true
		} else if name in ['gzip', 'zstd'] {
			if child.args.len > 2 || child.children.len > 0 { return error('expected gzip/zstd [level]') }
			args << name
			if child.args.len == 2 {
				if name == 'gzip' {
					level := strconv.atoi(child.args[1])!
					if level < -2 || level > 9 { return error('gzip level must be -2..9') }
					cfg.gzip_level = if level == 0 { 5 } else { level }
				} else {
					cfg.zstd_level = match child.args[1] {
						'fastest' { 1 }
						'default' { 3 }
						'better' { 7 }
						'best' { 19 }
						else { return error('zstd level must be fastest, default, better or best') }
					}
				}
			}
		} else { return error('unsupported encode option: ${name}') }
	}
	if args.len == 0 { args = ['zstd', 'gzip'] }
	for name in args {
		if name !in ['gzip', 'zstd'] || name in cfg.formats { return error('encode expects unique gzip/zstd formats') }
		cfg.formats << name
	}
	return cfg
}

fn resolve_encode(mut config EncodeConfig, matchers map[string][]string) ! {
	mut edits := [config.filter]
	resolve_header_matchers(mut edits, matchers)!
	config.filter = edits[0]
}

fn field_value(fields []Field, name string) string {
	return fields.filter(it.lower == name).map(it.value).join(', ')
}

fn accepted_encoding(fields []Field, formats []string) string {
	if field_value(fields, 'sec-websocket-key') != '' { return '' }
	mut best := ''
	mut best_q := f64(0)
	for format in formats {
		for entry in field_value(fields, 'accept-encoding').split(',') {
			parts := entry.split(';').map(it.trim_space())
			if parts[0].to_lower() != format { continue }
			mut q := f64(1)
			if parts.len > 1 && parts[1].to_lower().starts_with('q=') {
				value := strconv.atof64(parts[1][2..]) or { f64(1) }
				if value >= 0 && value <= 1 { q = value }
			}
			if q > best_q + 0.00001 { best_q = q; best = format }
		}
	}
	return best
}

fn encodable_type(value string) bool {
	type := value.to_lower().all_before(';').trim_space()
	if type.starts_with('text/') { return true }
	return type in ['application/atom+xml', 'application/eot', 'application/geo+json',
		'application/graphql+json', 'application/graphql-response+json', 'application/javascript',
		'application/json', 'application/ld+json', 'application/manifest+json', 'application/opentype',
		'application/otf', 'application/rss+xml', 'application/truetype', 'application/ttf',
		'application/vnd.api+json', 'application/vnd.ms-fontobject', 'application/wasm',
		'application/x-httpd-cgi', 'application/x-javascript', 'application/x-opentype',
		'application/x-otf', 'application/x-perl', 'application/x-protobuf', 'application/x-ttf',
		'application/xhtml+xml', 'application/xml', 'image/svg+xml', 'image/vnd.microsoft.icon',
		'image/x-icon', 'font/ttf', 'font/otf', 'multipart/bag', 'multipart/mixed'] || type.starts_with('application/font')
}

fn (mut c Connection) close_encoder() {
	if c.output.codec != unsafe { nil } { C.vaddy_encoder_free(c.output.codec); c.output.codec = unsafe { nil } }
}

fn (c &Connection) has_output_work() bool {
	return c.file_output.active || c.wire_output.len() > 0 || c.output.flush_pending || (c.to_client.len() > 0 && (!c.output.config.enabled || c.output.decided || c.tunnel))
}

fn (mut c Connection) prepare_output() ! {
	if !c.output.config.enabled || c.tunnel {
		c.to_client.transfer_to(mut c.wire_output)
		c.output.done = c.have_response && c.response.frame.done && c.to_client.len() == 0
		return
	}
	for !c.output.headers {
		raw := c.to_client.bytes().bytestr()
		end := raw.index('\r\n\r\n') or { return }
		m := parse_message_reuse(raw[..end + 4], false, c.request.method == 'HEAD', [])!
		if m.status < 200 {
			if c.wire_output.room() < end + 4 { return }
			c.wire_output.write_string(raw[..end + 4])
			c.to_client.skip(end + 4)
			continue
		}
		c.output.message = m
		c.output.frame = m.frame
		c.output.headers = true
		c.to_client.skip(end + 4)
	}
	if !c.output.decided {
		mut m := c.output.message
		ctype := field_value(m.fields, 'content-type')
		matches := if c.output.config.custom_response_filter { header_edit_matches(c.output.config.response_filter, m.fields, c.header_values, m.status) } else { encodable_type(ctype) }
		eligible := m.status !in [204, 206] && field_value(m.fields, 'content-encoding') == '' && !field_value(m.fields, 'cache-control').to_lower().split(',').map(it.trim_space()).contains('no-transform') && matches
		mut large := field_value(m.fields, 'content-length').i64() > c.output.config.minimum
		streaming := ctype.to_lower().starts_with('text/event-stream') || field_value(m.fields, 'incremental').trim_space() == '?1'
		if eligible && !large && !streaming && m.frame.kind in [.chunked, .eof] {
			mut frame := m.frame
			mut peek := Buffer{}
			frame.consume_decoded(c.to_client.bytes(), mut peek)!
			large = peek.len() > c.output.config.minimum
			if !large && !c.response.frame.done && !frame.done { return }
		}
		if (eligible && (large || streaming)) || m.status == 304 {
			if !field_value(m.fields, 'vary').to_lower().split(',').map(it.trim_space()).contains('accept-encoding') { m.fields << Field{'Vary', 'vary', 'Accept-Encoding'} }
		}
		if eligible && (large || streaming) && c.output.name != '' && m.status != 304 {
			m.fields = m.fields.filter(it.lower !in ['content-length', 'accept-ranges'])
			m.fields << Field{'Content-Encoding', 'content-encoding', c.output.name}
			for mut field in m.fields {
				if field.lower == 'etag' && field.value != '' && !field.value.starts_with('W/') { field = Field{...field, value: field.value.trim_string_right('"') + '-${c.output.name}"'} }
			}
			if c.request.method != 'HEAD' && !m.frame.done {
				kind := if c.output.name == 'gzip' { 1 } else { 2 }
				level := if kind == 1 { c.output.config.gzip_level } else { c.output.config.zstd_level }
				c.output.codec = C.vaddy_encoder_new(kind, level)
				if c.output.codec == unsafe { nil } { return error('cannot initialize response encoder') }
				m.frame = Framing{kind: .chunked}
			}
		}
		mut header := Buffer{}
		header.response_header(m, [], c.close_after)
		if c.wire_output.room() < header.len() { c.close_encoder(); return }
		c.wire_output.add(header.bytes())
		if c.access_targets.len > 0 { c.log_response_fields = m.fields.filter(!hop_header(it.lower, m.connection)) }
		c.output.decided = true
		if c.output.codec != unsafe { nil } { c.log_size = 0 }
	}
	if c.output.codec == unsafe { nil } {
		c.to_client.transfer_to(mut c.wire_output)
		c.output.done = c.response.frame.done && c.to_client.len() == 0
		return
	}
	if c.output.done || c.wire_output.room() < 64 { return }
	if c.output.pending.len() == 0 && c.to_client.len() > 0 {
		data := c.to_client.bytes()
		limit := if data.len > 16384 { 16384 } else { data.len }
		n := c.output.frame.consume_decoded(data[..limit], mut c.output.pending)!
		c.to_client.skip(n)
	}
	finish := c.response.frame.done && c.to_client.len() == 0
	mut scratch := [16384]u8{}
	room := c.wire_output.room() - 32
	capacity := if room < scratch.len { room } else { scratch.len }
	data := c.output.pending.bytes()
	if C.vaddy_encoder_step(c.output.codec, data.data, data.len, &scratch[0], capacity, int(finish)) != 0 { return error('response encoding failed') }
	c.output.pending.skip(c.output.codec.consumed)
	if c.output.codec.written > 0 {
		n := c.output.codec.written
		c.wire_output.write_string('${n:x}\r\n')
		c.wire_output.add(scratch[..n])
		c.wire_output.write_string('\r\n')
		c.log_size += n
	}
	if c.output.codec.finished != 0 {
		c.wire_output.write_string('0\r\n\r\n')
		c.output.done = true
	}
	c.output.flush_pending = !c.output.done && (c.output.pending.len() > 0 || c.output.codec.written == capacity || finish)
}
