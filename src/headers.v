module main

import net.urllib

struct HeaderEdit {
	name string
	lower string
	value string
	action u8
}

struct HeaderValues {
mut:
	uri string
	method string
	fields []Field
	remote_port string
	host string
	hostport string
	scheme string
	remote_host string
	upstream_hostport string
}

fn supported_placeholders(value string) bool {
	return !invalid_controls(value, true)
}

fn placeholder_value(name string, values HeaderValues) ?string {
	mut key := name.trim_string_left('http.request.')
	key = match key {
		'uri.path' { 'path' }
		'uri.query' { 'query' }
		'uri.prefixed_query' { '?query' }
		'remote.host' { 'remote_host' }
		'remote.port' { 'remote_port' }
		'http.reverse_proxy.upstream.hostport' { 'upstream_hostport' }
		else { key }
	}
	path := urllib.path_unescape(values.uri.all_before('?')) or { values.uri.all_before('?') }
	query := if values.uri.contains('?') { values.uri.all_after('?') } else { '' }
	match key {
		'uri', 'orig_uri' { return values.uri }
		'path', 'orig_uri.path' { return path }
		'query', 'orig_uri.query' { return query }
		'?query' { return if query == '' { '' } else { '?' + query } }
		'host' { return values.host }
		'hostport' { return values.hostport }
		'port' { return if values.hostport.contains(':') { values.hostport.all_after_last(':') } else { '' } }
		'scheme' { return values.scheme }
		'method', 'orig_method' { return values.method }
		'remote_host', 'client_ip', 'http.vars.client_ip' { return values.remote_host }
		'remote_port' { return values.remote_port }
		'remote' { return values.remote_host + ':' + values.remote_port }
		'upstream_hostport' { return values.upstream_hostport }
		else {}
	}
	if key.starts_with('header.') {
		field := key.trim_string_left('header.').to_lower()
		return values.fields.filter(it.lower == field).map(it.value).join(',')
	}
	if key.starts_with('query.') || key.starts_with('uri.query.') {
		field := key.trim_string_left('uri.').trim_string_left('query.')
		for pair in query.split('&') {
			if (urllib.query_unescape(pair.all_before('=')) or { '' }) == field {
				return urllib.query_unescape(pair.all_after('=')) or { '' }
			}
		}
		return ''
	}
	return none
}

fn parse_header_edit(args []string, nested bool, request bool) !HeaderEdit {
	if nested || args.len == 0 || args.len > 2 { return error('expected header name value, +name value, ?name value or -name') }
	mut name := args[0]
	mut action := u8(`=`)
	if name.len > 0 && name[0] in [u8(`+`), `-`, `?`] {
		action = name[0]
		name = name[1..]
	}
	lower := name.to_lower()
	if !is_token(name) || name.contains('*') || lower in ['content-length', 'transfer-encoding', 'connection', 'trailer', 'te', 'upgrade', 'keep-alive', 'proxy-connection', 'expect'] {
		return error('cannot edit framing or hop-by-hop header: ${name}')
	}
	if request && lower == 'host' && action != `=` { return error('Host may only be replaced') }
	if (action == `-` && args.len != 1) || (action != `-` && args.len != 2) { return error('invalid header arguments') }
	value := if args.len == 2 { args[1] } else { '' }
	if invalid_controls(value, true) || value.len > header_limit || !supported_placeholders(value) { return error('invalid header value or unsupported placeholder') }
	return HeaderEdit{name, lower, value, action}
}

fn parse_headers(d Directive, request bool) ![]HeaderEdit {
	mut result := []HeaderEdit{}
	if d.args.len > 1 {
		if d.children.len > 0 { return error('cannot mix inline header and block') }
		result << parse_header_edit(d.args[1..], false, request)!
	} else {
		if d.children.len == 0 { return error('empty header directive') }
		for child in d.children {
			result << parse_header_edit(child.args, child.children.len > 0, request)!
		}
	}
	return result
}

fn expand_header(value string, values HeaderValues) !string {
	output := expand_placeholders(value, values)!
	if invalid_controls(output, true) { return error('invalid expanded header') }
	return output
}

fn expand_placeholders(value string, values HeaderValues) !string {
	// Single pass: request values are never reinterpreted as placeholders.
	mut output := ''
	mut start := 0
	for start < value.len {
		if value[start] != `{` {
			end := value.index_after('{', start) or { value.len }
			output += value[start..end]
			start = end
		} else {
			end := value.index_after('}', start) or { output += value[start..]; break }
			output += placeholder_value(value[start + 1..end], values) or { value[start..end + 1] }
			start = end + 1
		}
		if output.len > header_limit { return error('expanded header too large') }
	}
	return output
}

// Edit only a complete, already serialized header block, before any body bytes
// are queued. Framing and upgrade fields cannot be changed by configuration.
fn edit_header_buffer(mut buffer Buffer, edits []HeaderEdit, values HeaderValues) ! {
	if buffer.len() > header_limit { return error('headers too large') }
	if edits.len == 0 { return }
	lines := buffer.bytes().bytestr().split('\r\n')
	mut fields := []Field{}
	for line in lines[1..] {
		if line == '' { break }
		name := line.all_before(':')
		fields << Field{name, name.to_lower(), line.all_after(':').trim_left(' \t')}
	}
	for edit in edits {
		if edit.action == `?` && fields.any(it.lower == edit.lower) { continue }
		if edit.action in [u8(`=`), `-`] { fields = fields.filter(it.lower != edit.lower) }
		if edit.action != `-` {
			value := expand_header(edit.value, values)!
			if edit.lower == 'host' && (value == '' || invalid_controls(value, false) || value.contains(' ') || value.contains('@') || value.contains('/') || value.contains('\\')) {
				return error('invalid Host replacement')
			}
			fields << Field{edit.name, edit.lower, value}
		}
	}
	if fields.len > 128 { return error('too many output headers') }
	mut output := Buffer{}
	output.write_string(lines[0] + '\r\n')
	for field in fields {
		if output.len() + field.name.len + field.value.len + 6 > header_limit { return error('edited headers too large') }
		output.write_string('${field.name}: ${field.value}\r\n')
	}
	output.write_string('\r\n')
	buffer.clear()
	buffer.add(output.bytes())
}
