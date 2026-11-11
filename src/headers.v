module main

import net.urllib

struct HeaderCondition {
	name string
	values []string
}

struct HeaderEdit {
	name string
	lower string
	value string
	search string
	action u8
	group string
	deferred bool
	proxy bool
	matcher string
	patterns []string
	statuses []int
	conditions []HeaderCondition
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
		mut values_found := []string{}
		for pair in query.split('&') {
			if (urllib.query_unescape(pair.all_before('=')) or { '' }) == field {
				values_found << if pair.contains('=') { urllib.query_unescape(pair.all_after('=')) or { '' } } else { '' }
			}
		}
		return values_found.join(',')
	}
	return none
}

fn protected_header(name string) bool {
	return name in ['content-length', 'transfer-encoding', 'connection', 'trailer', 'te', 'upgrade', 'keep-alive', 'proxy-connection', 'expect']
}

fn parse_header_edit(args []string, nested bool, request bool) !HeaderEdit {
	if nested || args.len == 0 || args.len > 3 { return error('expected header field [value [replacement]]') }
	mut name := args[0].trim_string_right(':')
	mut action := u8(`=`)
	if name.len > 0 && name[0] in [u8(`+`), `-`, `?`, `>`] {
		action = name[0]
		name = name[1..]
	}
	lower := name.to_lower()
	if (!is_token(name) && !name.contains('{')) || invalid_controls(name, false) || protected_header(lower) {
		return error('cannot edit framing or hop-by-hop header: ${name}')
	}
	if request && action == `?` { return error('default headers are response-only') }
	search := if args.len == 3 && action !in [u8(`+`), `-`, `?`] { args[1] } else { '' }
	value := if args.len == 3 && action !in [u8(`+`), `-`, `?`] { args[2] } else if args.len >= 2 { args[1] } else { '' }
	if search != '' && !search.contains('{') && C.vaddy_regex_valid(&char(search.str)) == 0 { return error('invalid regular expression') }
	if invalid_controls(value, true) || value.len > header_limit { return error('invalid header value') }
	return HeaderEdit{name: name, lower: lower, value: value, search: search, action: if args.len == 3 && action !in [u8(`+`), `-`, `?`] { u8(`r`) } else if action == `>` { u8(`=`) } else { action }, deferred: !request && action in [u8(`>`), `-`, `?`]}
}

fn parse_headers(d Directive, request bool) ![]HeaderEdit {
	mut args := d.args[1..].clone()
	mut matcher := ''
	mut patterns := []string{}
	if args.len > 0 && (args[0] == '*' || args[0].starts_with('/') || args[0].starts_with('@')) {
		if args[0].starts_with('@') { matcher = args[0] }
		else if args[0] != '*' { patterns = [args[0]] }
		args.delete(0)
	}
	mut result := []HeaderEdit{}
	mut defaults := []HeaderEdit{}
	mut deferred := false
	mut statuses := []int{}
	mut conditions := []HeaderCondition{}
	if args.len > 0 {
		if d.children.len > 0 { return error('cannot mix inline header and block') }
		result << parse_header_edit(args, false, request)!
	} else {
		if d.children.len == 0 { return error('empty header directive') }
		if request { return error('request_header requires inline arguments') }
		for child in d.children {
			if child.args == ['defer'] && child.children.len == 0 { deferred = true; continue }
			if child.args == ['match'] && child.children.len > 0 {
				deferred = true
				for condition in child.children {
					if condition.children.len > 0 || condition.args.len < 2 { return error('invalid response header condition') }
					if condition.args[0] == 'status' {
						for code in condition.args[1..] {
							if code.len == 3 && code.ends_with('xx') && code[0] in `1` .. `6` { statuses << code[..1].int() }
							else if code.len == 3 && all_digits(code) { statuses << code.int() }
							else { return error('invalid response status matcher') }
						}
					} else if condition.args[0] == 'header' {
						conditions << HeaderCondition{condition.args[1].to_lower(), condition.args[2..].clone()}
					} else { return error('response match supports status and header') }
				}
				continue
			}
			result << parse_header_edit(child.args, child.children.len > 0, request)!
		}
	}
	for edit in result { if edit.deferred && edit.action != `?` { deferred = true } }
	mut primary :=  []HeaderEdit{}
	for i, edit in result {
		if edit.action == `?` {
			if conditions.any(it.name == edit.lower && it.values.len > 0) { return error('cannot match a default header on its value') }
			defaults << HeaderEdit{...edit, group: '${d.line}:default:${i}', matcher: matcher, patterns: patterns, statuses: statuses, conditions: conditions}
		} else {
			primary << HeaderEdit{...edit, group: d.line.str(), deferred: deferred, matcher: matcher, patterns: patterns, statuses: statuses, conditions: conditions}
		}
	}
	primary << defaults
	return primary
}

fn resolve_header_matchers(mut edits []HeaderEdit, matchers map[string][]string) ! {
	for i, edit in edits {
		mut patterns := edit.patterns.clone()
		if edit.matcher != '' { patterns = matchers[edit.matcher] or { return error('undefined matcher ${edit.matcher}') } }
		for pattern in patterns {
			if !pattern.starts_with('/') || pattern.trim_string_right('*').contains('*') || pattern.contains('?') || pattern.contains('%') { return error('unsupported header path matcher') }
		}
		edits[i] = HeaderEdit{...edit, patterns: patterns.map(it.to_lower())}
	}
	for i in 1 .. edits.len {
		mut j := i
		for j > 0 && header_rule_before(edits[j], edits[j - 1]) {
			edits[j], edits[j - 1] = edits[j - 1], edits[j]
			j--
		}
	}
}

fn header_rule_before(a HeaderEdit, b HeaderEdit) bool {
	if a.patterns.len == 1 && b.patterns.len == 1 {
		ap := a.patterns[0].trim_string_right('*')
		bp := b.patterns[0].trim_string_right('*')
		if ap.len != bp.len { return ap.len > bp.len }
		return !a.patterns[0].ends_with('*') && b.patterns[0].ends_with('*')
	}
	return a.patterns.len > 0 && b.patterns.len == 0
}

fn header_pattern(pattern string, value string) bool {
	if pattern == '*' { return true }
	if pattern.starts_with('*') && pattern.ends_with('*') { return value.contains(pattern.trim('*')) }
	if pattern.starts_with('*') { return value.ends_with(pattern[1..]) }
	if pattern.ends_with('*') { return value.starts_with(pattern[..pattern.len - 1]) }
	return pattern == value
}

fn header_edit_matches(edit HeaderEdit, fields []Field, values HeaderValues, status int) bool {
	if edit.patterns.len > 0 {
		path := normalized_path(values.uri) or { return false }
		if !edit.patterns.any(header_pattern(it, path)) { return false }
	}
	if edit.statuses.len > 0 && status !in edit.statuses && status / 100 !in edit.statuses { return false }
	for condition in edit.conditions {
		name := condition.name.trim_string_left('!')
		matches := fields.filter(it.lower == name)
		if condition.name.starts_with('!') { if matches.len > 0 { return false }; continue }
		if matches.len == 0 { return false }
		if condition.values.len == 0 { continue }
		mut matched := false
		for field in matches {
			if condition.values.any(header_pattern(it, field.value)) { matched = true; break }
		}
		if !matched { return false }
	}
	return true
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

fn buffer_header_fields(buffer Buffer) []Field {
	mut fields := []Field{}
	raw := buffer.bytes().bytestr()
	mut start := (raw.index('\r\n') or { return fields }) + 2
	for start < raw.len {
		end := raw.index_after('\r\n', start) or { break }
		if end == start { break }
		colon := raw.index_after(':', start) or { break }
		if colon >= end { break }
		mut value := colon + 1
		for value < end && raw[value] in [u8(` `), `\t`] { value++ }
		name := raw[start..colon]
		fields << Field{name, name.to_lower_ascii(), raw[value..end]}
		start = end + 2
	}
	return fields
}

fn write_header_fields(mut buffer Buffer, fields []Field) ! {
	if fields.len > 128 { return error('too many output headers') }
	mut output := Buffer{}
	output.write_string(buffer.bytes().bytestr().all_before('\r\n') + '\r\n')
	for field in fields {
		if output.len() + field.name.len + field.value.len + 6 > header_limit { return error('edited headers too large') }
		output.write_string('${field.name}: ${field.value}\r\n')
	}
	output.write_string('\r\n')
	buffer.clear()
	buffer.add(output.bytes())
}

fn apply_header_group(mut fields []Field, edits []HeaderEdit, values HeaderValues, status int) ! {
	if edits.len == 0 || !header_edit_matches(edits[0], fields, values, status) { return }
	// Caddy groups operations by type, independently of their textual order.
	if edits.any(it.action == `-` && it.lower == '*') { fields = fields.filter(protected_header(it.lower)) }
	for action in [u8(`+`), `=`, `-`, `r`, `?`] {
		for original in edits {
			if original.action != action { continue }
			name := expand_header(original.name, values)!
			if !is_token(name) || protected_header(name.to_lower()) { return error('invalid expanded header name') }
			edit := HeaderEdit{...original, name: name, lower: name.to_lower()}
			if action == `?` && fields.any(it.lower == edit.lower) { continue }
			if action == `-` {
				if edit.lower == '*' { continue }
				fields = fields.filter(protected_header(it.lower) || !header_pattern(edit.lower, it.lower))
				continue
			}
			if action == `r` {
				pattern := expand_header(edit.search, values)!
				replacement := expand_header(edit.value, values)!
				// Invalid dynamically expanded patterns leave values unchanged, as in Caddy.
				if C.vaddy_regex_valid(&char(pattern.str)) == 0 { continue }
				for i, field in fields {
					if field.lower != edit.lower && edit.lower != '*' { continue }
					if protected_header(field.lower) { continue }
					value := regex_replace(pattern, replacement, field.value)!
					fields[i] = Field{...field, value: value}
				}
				continue
			}
			if action == `=` { fields = fields.filter(it.lower != edit.lower) }
			value := expand_header(edit.value, values)!
			if edit.lower == 'host' && (invalid_controls(value, false) || value.contains(' ') || value.contains('@') || value.contains('/') || value.contains('\\')) { return error('invalid Host replacement') }
			fields << Field{edit.name, edit.lower, value}
		}
	}
}

fn apply_header_edits(mut fields []Field, edits []HeaderEdit, values HeaderValues, status int, reverse bool) ! {
	mut groups := []string{}
	for edit in edits { if edit.group !in groups { groups << edit.group } }
	if reverse { groups.reverse_in_place() }
	for group in groups { apply_header_group(mut fields, edits.filter(it.group == group), values, status)! }
}

fn edit_header_buffer(mut buffer Buffer, edits []HeaderEdit, values HeaderValues) ! {
	if edits.len == 0 { return }
	mut fields := buffer_header_fields(buffer)
	apply_header_edits(mut fields, edits, values, 0, false)!
	write_header_fields(mut buffer, fields)!
}

fn response_header_buffer(mut buffer Buffer, edits []HeaderEdit, values HeaderValues, status int, local bool) ! {
	if edits.len == 0 { return }
	mut immediate := []Field{}
	apply_header_edits(mut immediate, edits.filter(!it.deferred && !it.proxy), values, status, false)!
	mut fields := buffer_header_fields(buffer)
	apply_header_edits(mut fields, edits.filter(it.proxy), values, status, false)!
	if local {
		// Static responses overwrite fields they own; proxies append upstream fields.
		for field in fields { immediate = immediate.filter(it.lower != field.lower) }
	}
	immediate << fields
	apply_header_edits(mut immediate, edits.filter(it.deferred && !it.proxy), values, status, true)!
	write_header_fields(mut buffer, immediate)!
}
