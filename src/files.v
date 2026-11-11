module main

import os
import time
import strconv
import net.urllib
import encoding.html
import x.json2

struct FileConfig {
mut:
	enabled bool
	browse bool
	canonical bool = true
	indexes []string = ['index.html', 'index.txt']
	hide []string
}

struct FileRange {
	start i64
	length i64
}

struct FileOutput {
mut:
	file os.File
	active bool
	ranges []FileRange
	index int
	remaining i64
	prefixes []string
	suffix string
	prefix_pending bool
}

fn parse_root(d Directive) !string {
	if d.children.len > 0 || d.args.len !in [2, 3] || (d.args.len == 3 && d.args[1] != '*') { return error('expected root [*] directory') }
	path := d.args.last()
	if path == '' || path.contains('{') || invalid_controls(path, false) { return error('root requires a literal directory') }
	return path
}

fn parse_file_server(d Directive) !Route {
	mut route := Route{files: FileConfig{enabled: true}}
	mut args := d.args[1..].clone()
	if args.len > 0 && (args[0].starts_with('/') || args[0].starts_with('@') || args[0] == '*') {
		if args[0].starts_with('@') { route.matcher = args[0] } else { route.patterns = [args[0]] }
		args.delete(0)
	}
	if args.len > 0 {
		if args != ['browse'] { return error('expected file_server [matcher] [browse]') }
		route.files.browse = true
	}
	for child in d.children {
		if child.args.len == 0 || child.children.len > 0 { return error('unsupported file_server block') }
		match child.args[0] {
			'browse' {
				if child.args.len != 1 { return error('custom browse templates are not supported') }
				route.files.browse = true
			}
			'root' { route.root = parse_root(child)! }
			'index' {
				if child.args.len < 2 { return error('file_server index needs file names') }
				for name in child.args[1..] { if name.contains('/') || name.contains('\\') || name in ['.', '..'] || invalid_controls(name, false) { return error('index must be a file name') } }
				route.files.indexes = child.args[1..].clone()
			}
			'hide' {
				if child.args.len < 2 { return error('file_server hide needs names or paths') }
				route.files.hide << child.args[1..]
			}
			'disable_canonical_uris' {
				if child.args.len != 1 { return error('disable_canonical_uris takes no arguments') }
				route.files.canonical = false
			}
			else { return error('unsupported file_server option: ${child.args[0]}') }
		}
	}
	return route
}

fn file_path(root string, uri string) !string {
	decoded := urllib.path_unescape(uri.all_before('?'))!
	if decoded.contains('\\') || decoded.contains(':') || invalid_controls(decoded, false) { return error('invalid file path') }
	mut parts := []string{}
	for part in decoded.split('/') {
		if part in ['', '.'] { continue }
		if part == '..' { if parts.len > 0 { parts.delete_last() }; continue }
		$if windows {
			base := part.all_before('.').to_upper()
			if part.ends_with('.') || part.ends_with(' ') || base in ['CON', 'PRN', 'AUX', 'NUL'] || (base.len == 4 && (base.starts_with('COM') || base.starts_with('LPT')) && base[3] in `1` .. `:`) { return error('invalid Windows file name') }
		}
		parts << part
	}
	return os.join_path(os.abs_path(root), ...parts)
}

fn file_hidden(path string, config FileConfig, config_path string) bool {
	abs := os.abs_path(path)
	if abs == os.abs_path(config_path) { return true }
	$if windows { if abs.to_lower() == os.abs_path(config_path).to_lower() { return true } }
	for pattern in config.hide {
		if pattern.contains('/') || pattern.contains('\\') {
			base := os.abs_path(pattern)
			if abs == base || abs.starts_with(base + os.path_separator) { return true }
		} else {
			for part in abs.replace('\\', '/').split('/') {
				if part.match_glob(pattern) { return true }
			}
		}
	}
	return false
}

fn parse_file_ranges(value string, size i64) ![]FileRange {
	if !value.starts_with('bytes=') { return error('invalid range unit') }
	parts := value[6..].split(',')
	if parts.len > 16 { return error('too many ranges') }
	mut ranges := []FileRange{}
	mut total := i64(0)
	for raw in parts {
		part := raw.trim_space()
		if !part.contains('-') { return error('invalid range') }
		left, right := part.all_before('-').trim_space(), part.all_after('-').trim_space()
		mut start := i64(0)
		mut end := size - 1
		if left == '' {
			if !all_digits(right) { return error('invalid suffix range') }
			length := strconv.parse_int(right, 10, 64)!
			if length == 0 || size == 0 { continue }
			start = if length < size { size - length } else { 0 }
		} else {
			if !all_digits(left) || (right != '' && !all_digits(right)) { return error('invalid range') }
			start = strconv.parse_int(left, 10, 64)!
			if right != '' { end = strconv.parse_int(right, 10, 64)! }
			if end < start { return error('invalid range order') }
			if start >= size { continue }
			if end >= size { end = size - 1 }
		}
		length := end - start + 1
		// Like ServeContent, ignore ranges whose aggregate length exceeds the file.
		if length > size - total { return []FileRange{} }
		total += length
		ranges << FileRange{start, length}
	}
	if ranges.len == 0 { return error('range does not overlap file') }
	return ranges
}

fn etag_matches(value string, etag string, weak bool) bool {
	for raw in value.split(',') {
		item := raw.trim_space()
		if item == '*' { return true }
		if weak {
			if item.trim_string_left('W/') == etag.trim_string_left('W/') { return true }
		} else if !item.starts_with('W/') && item == etag { return true }
	}
	return false
}

fn http_date(value string) ?i64 {
	return (time.parse_http_header_string(value) or { return none }).unix()
}

fn file_condition(fields []Field, etag string, modified i64) int {
	match_tag := field_value(fields, 'if-match')
	if match_tag != '' {
		if !etag_matches(match_tag, etag, false) { return 412 }
	} else if since := http_date(field_value(fields, 'if-unmodified-since')) {
		if modified > since { return 412 }
	}
	none_tag := field_value(fields, 'if-none-match')
	if none_tag != '' {
		if etag_matches(none_tag, etag, true) { return 304 }
	} else if since := http_date(field_value(fields, 'if-modified-since')) {
		if modified <= since { return 304 }
	}
	return 200
}

fn (mut c Connection) close_file() {
	if c.file_output.active { c.file_output.file.close(); c.file_output.active = false }
}

fn (mut c Connection) pump_file() ! {
	if !c.file_output.active || c.response.frame.done { return }
	if c.file_output.prefix_pending {
		prefix := c.file_output.prefixes[c.file_output.index]
		if c.to_client.room() < prefix.len { return }
		c.to_client.write_string(prefix)
		c.response.frame.consume(prefix.bytes())!
		c.file_output.prefix_pending = false
	}
	mut scratch := [16384]u8{}
	mut limit := if c.to_client.room() < scratch.len { c.to_client.room() } else { scratch.len }
	if c.file_output.remaining < limit { limit = int(c.file_output.remaining) }
	if limit > 0 {
		n := c.file_output.file.read_into_ptr(&scratch[0], limit)!
		if n == 0 { return error('static file truncated during response') }
		c.to_client.add(scratch[..n])
		c.response.frame.consume(scratch[..n])!
		c.file_output.remaining -= n
	}
	if c.file_output.remaining == 0 {
		if c.file_output.index + 1 < c.file_output.ranges.len {
			c.file_output.index++
			range := c.file_output.ranges[c.file_output.index]
			c.file_output.file.seek(range.start, .start)!
			c.file_output.remaining = range.length
			c.file_output.prefix_pending = true
		} else if c.to_client.room() >= c.file_output.suffix.len {
			c.to_client.write_string(c.file_output.suffix)
			c.response.frame.consume(c.file_output.suffix.bytes())!
			c.close_file()
		}
	}
	if c.output.codec == unsafe { nil } { c.log_size = c.response.frame.body_bytes }
}

fn (mut s Server) serve_file(mut c Connection, site Site, route Route, request_fields []Field) ! {
	if c.request.method !in ['GET', 'HEAD'] {
		s.respond_options(mut c, 405, 'Method Not Allowed', '', 'Allow: GET, HEAD\r\n', true, '')
		return
	}
	uri := rewrite_uri(c.request.uri, route.rewrite)
	root := if route.root != '' { route.root } else { site.root }
	mut path := file_path(root, uri) or { s.respond(mut c, 400, 'Bad Request', '', ''); return }
	if file_hidden(path, route.files, s.opts.config) { s.respond_options(mut c, 404, 'Not Found', '', '', true, ''); return }
	info := os.stat(path) or { s.respond_options(mut c, 404, 'Not Found', '', '', true, ''); return }
	is_dir := info.get_filetype() == .directory
	if is_dir {
		mut found := false
		for index in route.files.indexes {
			candidate := os.join_path(path, index)
			if os.is_file(candidate) && !file_hidden(candidate, route.files, s.opts.config) { path = candidate; found = true; break }
		}
		if !found {
			if route.files.browse { s.browse_directory(mut c, path, uri, route.files, request_fields)! }
			else { s.respond_options(mut c, 404, 'Not Found', '', '', true, '') }
			return
		}
	} else if info.get_filetype() != .regular {
		s.respond_options(mut c, 404, 'Not Found', '', '', true, '')
		return
	}
	url_path := uri.all_before('?')
	if route.files.canonical && route.rewrite == '' && is_dir != url_path.ends_with('/') {
		target := if is_dir { url_path + '/' } else { url_path.trim_right('/') }
		query := if uri.contains('?') { '?' + uri.all_after('?') } else { '' }
		s.file_redirect(mut c, target + query)
		return
	}
	if !is_dir && url_path.ends_with('/') { s.respond_options(mut c, 404, 'Not Found', '', '', true, ''); return }
	mut file := os.open_file(path, 'rbn') or { s.respond_options(mut c, 403, 'Forbidden', '', '', true, ''); return }
	mut stat := C.vaddy_file_info{}
	if C.vaddy_file_info(file.fd, &stat) != 0 { file.close(); s.respond_options(mut c, 404, 'Not Found', '', '', true, ''); return }
	modified := stat.modified / 1000000000
	etag := '"${strconv.format_int(stat.modified, 36)}-${strconv.format_int(stat.size, 36)}"'
	last_modified := time.unix(modified).http_header_string()
	mut condition_fields := request_fields.clone()
	if c.output.name != '' {
		for mut field in condition_fields { if field.lower == 'if-none-match' { field = Field{...field, value: field.value.replace('-${c.output.name}"', '"')} } }
	}
	status := file_condition(condition_fields, etag, modified)
	if status != 200 {
		file.close()
		extra := if status == 304 { 'Etag: ${etag}\r\n' } else { 'Etag: ${etag}\r\nLast-Modified: ${last_modified}\r\n' }
		s.respond_options(mut c, status, if status == 304 { 'Not Modified' } else { 'Precondition Failed' }, '', extra, true, '')
		return
	}
	mut ranges := []FileRange{}
	mut range_header := field_value(request_fields, 'range')
	if_range := field_value(request_fields, 'if-range')
	if if_range != '' {
		if if_range.starts_with('"') || if_range.starts_with('W/') {
			if if_range != etag { range_header = '' }
		} else if since := http_date(if_range) {
			if since != modified { range_header = '' }
		} else { range_header = '' }
	}
	if range_header != '' && c.request.method == 'GET' {
		ranges = parse_file_ranges(range_header, stat.size) or {
			file.close()
			s.respond_options(mut c, 416, 'Range Not Satisfiable', '', 'Content-Range: bytes */${stat.size}\r\n', true, '')
			return
		}
	}
	code := if ranges.len > 0 { 206 } else { 200 }
	if ranges.len == 0 { ranges = [FileRange{0, stat.size}] }
	mut content_type := file_mime_type(os.file_ext(path).trim_left('.').to_lower())
	// Like Caddy, do not sniff extensionless or unknown files into executable HTML.
	if os.file_ext(path).to_lower() in ['.js', '.mjs'] { content_type = 'text/javascript' }
	if content_type.starts_with('text/') && !content_type.contains(';') { content_type += '; charset=utf-8' }
	mut prefixes := ['']
	mut suffix := ''
	mut length := ranges[0].length
	mut extra := ''
	if code == 206 && ranges.len == 1 { extra = 'Content-Range: bytes ${ranges[0].start}-${ranges[0].start + ranges[0].length - 1}/${stat.size}\r\n' }
	if ranges.len > 1 {
		id := new_reload_id() or { file.close(); return err }
		boundary := 'vaddy-${id}'
		prefixes = []string{}
		length = 0
		for i, range in ranges {
			prefix := '${if i == 0 { '' } else { '\r\n' }}--${boundary}\r\nContent-Range: bytes ${range.start}-${range.start + range.length - 1}/${stat.size}\r\nContent-Type: ${content_type}\r\n\r\n'
			prefixes << prefix
			length += prefix.len + range.length
		}
		suffix = '\r\n--${boundary}--\r\n'
		length += suffix.len
		content_type = 'multipart/byteranges; boundary=${boundary}'
	}
	file.seek(ranges[0].start, .start) or { file.close(); return err }
	c.file_output = FileOutput{file: file, active: true, ranges: ranges, remaining: ranges[0].length, prefixes: prefixes, suffix: suffix, prefix_pending: true}
	c.local = true
	c.have_response = true
	c.close_after = c.request.close || s.draining || c.request.expect || c.request.frame.kind == .chunked || c.request.frame.remaining > 262144 || c.requests >= s.opts.max_keepalive_requests - 1
	type_header := if content_type == '' { '' } else { 'Content-Type: ${content_type}\r\n' }
	raw := 'HTTP/1.1 ${code} ${if code == 200 { 'OK' } else { 'Partial Content' }}\r\nContent-Length: ${length}\r\n${type_header}Etag: ${etag}\r\nLast-Modified: ${last_modified}\r\nAccept-Ranges: bytes\r\n${extra}\r\n'
	c.response = parse_message_reuse(raw, false, c.request.method == 'HEAD', [])!
	c.log_status = code
	s.write_response_header(mut c, c.response, c.close_after)!
	if c.request.method == 'HEAD' || length == 0 { c.close_file() }
}

fn (mut s Server) browse_directory(mut c Connection, path string, uri string, config FileConfig, request_fields []Field) ! {
	if config.canonical && !uri.all_before('?').ends_with('/') {
		target := uri.all_before('?') + '/' + if uri.contains('?') { '?' + uri.all_after('?') } else { '' }
		s.file_redirect(mut c, target)
		return
	}
	mut names := os.ls(path) or { s.respond_options(mut c, 403, 'Forbidden', '', '', true, ''); return }
	names.sort()
	mut listing := '<!doctype html><meta charset="utf-8"><title>Directory listing</title><h1>${html.escape(uri.all_before('?'))}</h1><ul>'
	mut entries := []json2.Any{}
	for name in names {
		filename := os.join_path(path, name)
		if file_hidden(filename, config, s.opts.config) { continue }
		stat := os.stat(filename) or { continue }
		dir := stat.get_filetype() == .directory
		if !dir && stat.get_filetype() != .regular { continue }
		label := name + if dir { '/' } else { '' }
		url := urllib.path_escape(name) + if dir { '/' } else { '' }
		listing += '<li><a href="${html.escape(url)}">${html.escape(label)}</a></li>'
		entries << json2.Any({'name': json2.Any(label), 'size': json2.Any(stat.size), 'url': json2.Any('./' + url), 'mod_time': json2.Any(time.unix(stat.mtime).format_rfc3339()), 'is_dir': json2.Any(dir), 'is_symlink': json2.Any(os.is_link(filename))})
		if listing.len > 24000 || entries.len > 512 { s.respond_options(mut c, 503, 'Service Unavailable', '', '', true, ''); return }
	}
	listing += '</ul>'
	json := field_value(request_fields, 'accept').contains('application/json')
	body := if json { json2.encode(entries) } else { listing }
	if body.len > 24000 { s.respond_options(mut c, 503, 'Service Unavailable', '', '', true, ''); return }
	s.respond_options(mut c, 200, 'OK', body, '', true, if json { 'application/json; charset=utf-8' } else { 'text/html; charset=utf-8' })
}

fn (mut s Server) file_redirect(mut c Connection, target string) {
	location := '/' + target.trim_left('/')
	body := if c.request.method == 'GET' { '<a href="${html.escape(location)}">Permanent Redirect</a>.\n\n' } else { '' }
	s.respond_options(mut c, 308, 'Permanent Redirect', body, 'Location: ${location}\r\n', true, 'text/html; charset=utf-8')
}
