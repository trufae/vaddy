module main

import x.json2
import crypto.sha256
import net.urllib
import time

struct LogFilter {
	path []string
	kind string
	args []string
	actions []Directive
}

struct LogFormat {
mut:
	kind string = 'json'
	filters []LogFilter
	fields map[string]json2.Any
	keys map[string]string
	time_format string = 'unix_seconds_float'
	duration_format string = 'seconds'
	level_format string = 'lower'
}

fn parse_log_format(d Directive) !LogFormat {
	if d.args.len != 2 || d.args[1] !in ['json', 'console', 'filter', 'append'] { return error('unsupported log encoder') }
	mut format := LogFormat{}
	if d.args[1] == 'console' { format.kind = 'console'; format.time_format = 'wall_milli'; format.level_format = 'color' }
	for child in d.children {
		if child.args == ['fields'] && d.args[1] in ['filter', 'append'] {
			for field in child.children {
				if d.args[1] == 'append' {
					if field.args.len != 2 || field.children.len > 0 { return error('expected appended log field and value') }
					format.fields[field.args[0]] = json2.decode[json2.Any](field.args[1]) or { json2.Any(field.args[1]) }
				} else { format.filters << parse_log_filter(field)! }
			}
			continue
		}
		if child.args.len == 2 && child.args[0] == 'wrap' && child.args[1] in ['json', 'console'] {
			wrapped := parse_log_format(Directive{args: ['format', child.args[1]], children: child.children})!
			format.kind = wrapped.kind
			format.time_format = wrapped.time_format
			format.duration_format = wrapped.duration_format
			format.level_format = wrapped.level_format
			format.keys = wrapped.keys.clone()
			continue
		}
		if child.args.len != 2 || child.children.len > 0 { return error('invalid log encoder option') }
		name, value := child.args[0], child.args[1]
		match name {
			'message_key' { format.keys['msg'] = value }
			'level_key' { format.keys['level'] = value }
			'time_key' { format.keys['ts'] = value }
			'name_key' { format.keys['logger'] = value }
			'time_format' {
				if value !in ['unix_seconds_float', 'unix_milli_float', 'unix_nano', 'rfc3339', 'rfc3339_nano', 'wall', 'wall_milli'] { return error('unsupported log time format') }
				format.time_format = value
			}
			'duration_format' {
				if value !in ['s', 'second', 'seconds', 'ns', 'nano', 'nanos', 'ms', 'milli', 'millis', 'string'] { return error('unsupported duration format') }
				format.duration_format = value
			}
			'level_format' {
				if value !in ['lower', 'upper', 'color'] { return error('invalid level format') }
				format.level_format = value
			}
			else { return error('unsupported log encoder option ${name}') }
		}
	}
	return format
}

fn parse_log_filter(d Directive) !LogFilter {
	if d.args.len < 2 { return error('expected log field filter') }
	kind := d.args[1]
	args := d.args[2..].clone()
	match kind {
		'delete', 'hash' { if args.len != 0 || d.children.len > 0 { return error('unexpected filter arguments') } }
		'replace', 'rename' { if args.len != 1 || d.children.len > 0 { return error('expected filter value') } }
		'regexp' {
			if args.len != 2 || d.children.len > 0 || C.vaddy_regex_valid(&char(args[0].str)) == 0 { return error('invalid regexp filter') }
		}
		'query', 'cookie', 'set_cookie' {
			if args.len != 0 { return error('unexpected filter arguments') }
			for action in d.children {
				if action.args.len < 2 || action.args[0] !in ['delete', 'hash', 'replace'] || action.children.len > 0 { return error('invalid filter action') }
				if action.args.len != (if action.args[0] == 'replace' { 3 } else { 2 }) { return error('invalid filter action arguments') }
			}
		}
		else { return error('unsupported log filter ${kind}') }
	}
	return LogFilter{d.args[0].split('>'), kind, args, d.children}
}

fn filter_log_string(value string, filter LogFilter) !string {
	match filter.kind {
		'hash' { return sha256.hexhash(value)[..8] }
		'regexp' { return regex_replace(filter.args[0], filter.args[1], value)! }
		'query' {
			mut url := urllib.parse(value) or { return value }
			mut query := urllib.parse_query(url.raw_query) or { return value }
			for action in filter.actions {
				name := action.args[1]
				values := query.get_all(name)
				query.data = query.data.filter(it.key != name)
				query.len = query.data.len
				if action.args[0] == 'delete' { continue }
				for item in values { query.add(name, if action.args[0] == 'hash' { sha256.hexhash(item)[..8] } else { action.args[2] }) }
			}
			mut keys := []string{}
			for item in query.data { if item.key !in keys { keys << item.key } }
			keys.sort()
			mut encoded := []string{}
			for key in keys {
				for item in query.get_all(key) { encoded << urllib.query_escape(key) + '=' + urllib.query_escape(item) }
			}
			url.raw_query = encoded.join('&')
			return url.str()
		}
		'cookie', 'set_cookie' {
			mut parts := []string{}
			for i, raw in value.split(';') {
				part := raw.trim_space()
				if !part.contains('=') || (filter.kind == 'set_cookie' && i > 0) { parts << part; continue }
				name := part.all_before('=')
				mut content := part.all_after('=')
				mut deleted := false
				for action in filter.actions {
					if action.args[1] != name { continue }
					if action.args[0] == 'delete' { deleted = true; break }
					content = if action.args[0] == 'hash' { sha256.hexhash(content.trim('"'))[..8] } else { action.args[2] }
				}
				if deleted { if filter.kind == 'set_cookie' { return '' }; continue }
				parts << '${name}=${content}'
			}
			return parts.join('; ')
		}
		else { return value }
	}
}

fn filter_log_value(value json2.Any, filter LogFilter) !json2.Any {
	if filter.kind == 'replace' { return filter.args[0] }
	if value is string { return filter_log_string(value, filter)! }
	if value is []json2.Any {
		mut result := []json2.Any{}
		for item in value {
			if item is string {
				filtered := filter_log_string(item, filter)!
				if filter.kind == 'set_cookie' && filtered == '' { continue }
				result << json2.Any(filtered)
			} else { result << item }
		}
		return result
	}
	return value
}

fn apply_log_filter(value json2.Any, filter LogFilter, depth int) !json2.Any {
	if value is map[string]json2.Any {
		mut result := map[string]json2.Any{}
		for key, item in value {
			if filter.path[depth] != key && filter.path[depth] != '*' { result[key] = item; continue }
			if depth + 1 < filter.path.len { result[key] = apply_log_filter(item, filter, depth + 1)!; continue }
			if filter.kind == 'delete' { continue }
			else if filter.kind == 'rename' { result[filter.args[0]] = item }
			else { result[key] = filter_log_value(item, filter)! }
		}
		return result
	}
	return value
}

fn encode_access_record(record AccessRecord, format LogFormat, extra map[string]json2.Any) !string {
	if format == LogFormat{} && extra.len == 0 { return json2.encode(record, escape_unicode: true) }
	mut fields := json2.decode[map[string]json2.Any](json2.encode(record))!
	for key, value in format.fields { fields[key] = value }
	for key, value in extra { fields[key] = value }
	stamp := time.unix_nano(i64(record.ts * 1e9))
	fields['ts'] = match format.time_format {
		'unix_milli_float' { json2.Any(record.ts * 1000) }
		'unix_nano' { json2.Any(i64(record.ts * 1e9)) }
		'rfc3339' { json2.Any(stamp.format_rfc3339().all_before('.') + 'Z') }
		'rfc3339_nano' { json2.Any(stamp.format_rfc3339_nano()) }
		'wall' { json2.Any(stamp.format_ss().replace('-', '/')) }
		'wall_milli' { json2.Any(stamp.format_ss_milli().replace('-', '/')) }
		else { json2.Any(record.ts) }
	}
	fields['duration'] = match format.duration_format {
		'ns', 'nano', 'nanos' { json2.Any(i64(record.duration * 1e9)) }
		'ms', 'milli', 'millis' { json2.Any(i64(record.duration * 1000)) }
		'string' { json2.Any(time.Duration(record.duration * 1e9).str()) }
		else { json2.Any(record.duration) }
	}
	if format.level_format != 'lower' { fields['level'] = record.level.to_upper() }
	if format.level_format == 'color' {
		color := match record.level { 'debug' { '35' } 'warn' { '33' } 'error' { '31' } else { '34' } }
		fields['level'] = '\x1b[${color}m${record.level.to_upper()}\x1b[0m'
	}
	for filter in format.filters { fields = apply_log_filter(fields, filter, 0)!.as_map() }
	if format.kind == 'console' {
		mut parts := []string{}
		for key in ['ts', 'level', 'logger', 'msg'] { if value := fields[key] { parts << value.str() } }
		prefix := parts.join('\t')
		for key in ['ts', 'level', 'logger', 'msg'] { fields.delete(key) }
		return prefix + '\t' + json2.encode(fields, escape_unicode: true)
	}
	for old, name in format.keys {
		if value := fields[old] { fields.delete(old); if name != '' { fields[name] = value } }
	}
	return json2.encode(fields, escape_unicode: true)
}
