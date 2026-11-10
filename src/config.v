module main

import net.urllib

struct Directive {
	args     []string
	children []Directive
	line     int
}

struct Token {
	text string
	line int
}

struct Route {
mut:
	patterns []string
	matcher  string
	rewrite  string
	upstream string
}

struct Site {
mut:
	hosts          []string
	plain          bool
	remove_headers []string
	routes         []Route
	matchers       map[string][]string
	tls_mode       string = 'auto'
	cert           string
	key            string
}

struct Config {
mut:
	sites      []Site
	http_port  int = 80
	https_port int = 443
	email      string
	acme_ca    string = 'https://acme-v02.api.letsencrypt.org/directory'
}

fn tokenize(input string) ![]Token {
	mut tokens := []Token{}
	mut i := 0
	mut line := 1
	for i < input.len {
		c := input[i]
		if c == `\n` {
			tokens << Token{'\n', line}
			line++
			i++
			continue
		}
		if c in [u8(` `), `\t`, `\r`] {
			i++
			continue
		}
		if c == `#` {
			for i < input.len && input[i] != `\n` { i++ }
			continue
		}
		start := i
		if c == `"` {
			i++
			mut value := []u8{}
			for i < input.len && input[i] != `"` {
				if input[i] == `\n` { return error('line ${line}: newline in quoted token') }
				if input[i] == `\\` && i + 1 < input.len { i++ }
				value << input[i]
				i++
			}
			if i == input.len { return error('line ${line}: unterminated quote') }
			i++
			tokens << Token{value.bytestr(), line}
		} else {
			for i < input.len && input[i] !in [u8(` `), `\t`, `\r`, `\n`] { i++ }
			tokens << Token{input[start..i], line}
		}
	}
	return tokens
}

struct Cursor {
mut:
	pos int
}

fn parse_nodes(tokens []Token, mut cursor Cursor, nested bool) ![]Directive {
	mut nodes := []Directive{}
	for cursor.pos < tokens.len {
		if tokens[cursor.pos].text == '\n' {
			cursor.pos++
			continue
		}
		if tokens[cursor.pos].text == '}' {
			if !nested { return error('line ${tokens[cursor.pos].line}: unexpected }') }
			cursor.pos++
			return nodes
		}
		line := tokens[cursor.pos].line
		mut args := []string{}
		for cursor.pos < tokens.len && tokens[cursor.pos].text !in ['\n', '{', '}'] {
			args << tokens[cursor.pos].text
			cursor.pos++
		}
		mut children := []Directive{}
		if cursor.pos < tokens.len && tokens[cursor.pos].text == '{' {
			cursor.pos++
			children = parse_nodes(tokens, mut cursor, true)!
		} else if args.len == 0 {
			return error('line ${line}: expected directive')
		}
		nodes << Directive{args, children, line}
	}
	if nested { return error('missing closing }') }
	return nodes
}

fn valid_host(host string) bool {
	if host.len == 0 || host.len > 253 { return false }
	mut label := 0
	for i in 0 .. host.len {
		c := host[i]
		if c == `.` {
			if label == 0 || host[i - 1] == `-` { return false }
			label = 0
			continue
		}
		if !c.is_alnum() && (c != `-` || label == 0) { return false }
		label++
		if label > 63 { return false }
	}
	return label > 0 && host[host.len - 1] != `-`
}

fn port_value(s string) !int {
	if s.len == 0 || s.len > 5 || !all_digits(s) || s.int() < 1 || s.int() > 65535 {
		return error('invalid port: ${s}')
	}
	return s.int()
}

fn upstream_address(s string) !string {
	value := s.trim_string_left('http://')
	u := urllib.parse('http://${value}')!
	if u.host == '' || u.path !in ['', '/'] || u.raw_query != '' || u.fragment != '' || s.contains('https://') || value.contains('@') {
		return error('reverse_proxy requires one plain HTTP host:port upstream')
	}
	if u.port() == '' { return '${u.host}:80' }
	port_value(u.port())!
	return u.host
}

fn parse_route(d Directive) !Route {
	mut route := Route{}
	if d.args.len > 2 { return error('line ${d.line}: handle accepts one matcher') }
	if d.args.len == 2 {
		m := d.args[1]
		if m.starts_with('@') {
			route.matcher = m
		} else if m.starts_with('/') || m == '*' {
			route.patterns = [m]
		} else {
			return error('line ${d.line}: unsupported handle matcher ${m}')
		}
	}
	for child in d.children {
		if child.args.len == 0 || child.children.len > 0 {
			return error('line ${child.line}: unsupported nested directive')
		}
		match child.args[0] {
			'rewrite' {
				if child.args.len != 3 || child.args[1] != '*' || route.rewrite != '' {
					return error('line ${child.line}: expected rewrite * /target')
				}
				route.rewrite = child.args[2]
				if !route.rewrite.starts_with('/') || route.rewrite.replace('{uri}', '').contains('{') || route.rewrite.bytes().any(it < 33 || it == 127) {
					return error('unsupported rewrite: ${route.rewrite}')
				}
			}
			'reverse_proxy' {
				if child.args.len != 2 || route.upstream != '' {
					return error('line ${child.line}: expected reverse_proxy host:port')
				}
				route.upstream = upstream_address(child.args[1])!
			}
			else {
				return error('line ${child.line}: unsupported handle directive ${child.args[0]}')
			}
		}
	}
	if route.upstream == '' { return error('line ${d.line}: handle needs reverse_proxy') }
	return route
}

fn route_before(a Route, b Route) bool {
	if a.patterns.len == 1 && b.patterns.len == 1 {
		ap := a.patterns[0].trim_string_right('*')
		bp := b.patterns[0].trim_string_right('*')
		if ap == bp { return a.patterns[0].len < b.patterns[0].len }
		if ap.len == bp.len { return ap < bp }
		return ap.len > bp.len
	}
	return a.patterns.len > 0 && b.patterns.len == 0
}

fn parse_config(input string) !Config {
	tokens := tokenize(input)!
	mut cursor := Cursor{}
	nodes := parse_nodes(tokens, mut cursor, false)!
	mut cfg := Config{}
	mut hosts := map[string]bool{}
	for idx, d in nodes {
		if d.args.len == 0 {
			if idx != 0 { return error('global block must be first') }
			for opt in d.children {
				if opt.args.len != 2 || opt.children.len > 0 {
					return error('line ${opt.line}: unsupported global option')
				}
				match opt.args[0] {
					'admin' {
						if opt.args[1] != 'off' { return error('only admin off is supported') }
					}
					'http_port' { cfg.http_port = port_value(opt.args[1])! }
					'https_port' { cfg.https_port = port_value(opt.args[1])! }
					'email' { cfg.email = opt.args[1] }
					'acme_ca' { cfg.acme_ca = opt.args[1] }
					else {
						return error('line ${opt.line}: unsupported global option ${opt.args[0]}')
					}
				}
			}
			continue
		}
		mut site := Site{}
		for addr in d.args {
			host := addr.trim_right(',').trim_string_left('https://').trim_string_left('http://').to_lower()
			plain := addr.starts_with('http://')
			if !valid_host(host) {
				return error('line ${d.line}: expected DNS hostname (use global http_port/https_port for alternate ports): ${addr}')
			}
			if site.hosts.len > 0 && plain != site.plain {
				return error('cannot mix HTTP and HTTPS addresses in a site')
			}
			if host in hosts { return error('duplicate site: ${host}') }
			hosts[host] = true
			site.hosts << host
			site.plain = plain
		}
		for child in d.children {
			if child.args.len == 0 { return error('line ${child.line}: unexpected block') }
			name := child.args[0]
			if name.starts_with('@') {
				if child.args.len < 3 || child.args[1] != 'path' || child.children.len > 0 || name in site.matchers {
					return error('line ${child.line}: expected unique @name path /pattern ...')
				}
				site.matchers[name] = child.args[2..].clone()
				continue
			}
			match name {
				'header' {
					mut entries := child.children.clone()
					if child.args.len > 1 { entries << Directive{ args: child.args[1..] } }
					for h in entries {
						if h.args.len != 1 || !h.args[0].starts_with('-') || !is_token(h.args[0][1..]) || h.children.len > 0 {
							return error('line ${h.line}: only header -Name is supported')
						}
						hname := h.args[0][1..].to_lower()
						if hname in ['content-length', 'transfer-encoding', 'connection'] {
							return error('cannot remove HTTP framing header ${hname}')
						}
						site.remove_headers << hname
					}
				}
				'handle' { site.routes << parse_route(child)! }
				'reverse_proxy' {
					if child.args.len != 2 || child.children.len > 0 {
						return error('expected reverse_proxy host:port')
					}
					site.routes << Route{ upstream: upstream_address(child.args[1])! }
				}
				'tls' {
					if child.children.len > 0 { return error('tls blocks are not supported') }
					if child.args.len == 2 && child.args[1] == 'internal' {
						site.tls_mode = 'internal'
					} else if child.args.len == 3 {
						site.tls_mode = 'manual'
						site.cert = child.args[1]
						site.key = child.args[2]
					} else {
						return error('expected tls internal or tls cert.pem key.pem')
					}
				}
				else { return error('line ${child.line}: unsupported directive ${name}') }
			}
		}
		if site.routes.len == 0 { return error('site needs a reverse_proxy or handle') }
		mut fallbacks := 0
		for mut route in site.routes {
			if route.matcher != '' {
				if route.matcher !in site.matchers {
					return error('undefined matcher ${route.matcher}')
				}
				route.patterns = site.matchers[route.matcher].clone()
			}
			for pattern in route.patterns {
				if pattern != '*' && (!pattern.starts_with('/') || pattern.trim_string_right('*').contains('*') || pattern.contains('?') || pattern.contains('%') || pattern.contains('[') || pattern.contains('//')) {
					return error('only exact paths and trailing * path matchers are supported: ${pattern}')
				}
			}
			route.patterns = route.patterns.map(it.to_lower())
			if route.patterns.len == 0 { fallbacks++ }
		}
		if fallbacks > 1 { return error('site has multiple fallback routes') }
		// Stable insertion sort follows Caddy's single-path specificity and fallback rules.
		for i in 1 .. site.routes.len {
			mut j := i
			for j > 0 && route_before(site.routes[j], site.routes[j - 1]) {
				site.routes[j], site.routes[j - 1] = site.routes[j - 1], site.routes[j]
				j--
			}
		}
		cfg.sites << site
	}
	if cfg.sites.len == 0 { return error('no sites configured') }
	if cfg.http_port == cfg.https_port { return error('HTTP and HTTPS ports must differ') }
	mut policy := ''
	for site in cfg.sites {
		if site.plain { continue }
		p := '${site.tls_mode}|${site.cert}|${site.key}'
		if policy != '' && policy != p {
			return error('HTTPS sites must share one TLS policy; certificates cover all configured names')
		}
		policy = p
	}
	return cfg
}

fn (cfg Config) tls_site() ?Site {
	for site in cfg.sites { if !site.plain { return site } }
	return none
}

fn (cfg Config) domains() []string {
	mut result := []string{}
	for site in cfg.sites { if !site.plain { result << site.hosts } }
	return result
}

fn (cfg Config) site_index(host string) int {
	name := host.all_before(':').trim_right('.').to_lower()
	for i, site in cfg.sites { if name in site.hosts { return i } }
	return -1
}

fn (site Site) route_for(uri string) ?Route {
	unescaped := urllib.path_unescape(uri.all_before('?')) or { return none }
	path := unescaped.to_lower()
	// Most paths are already normalized; avoid splitting and rebuilding those.
	mut matched_path := path
	if path.contains('/.') || path.contains('//') {
		mut segments := []string{}
		for segment in path.split('/') {
			if segment == '..' {
				if segments.len > 0 { segments.delete_last() }
			} else if segment !in ['', '.'] {
				segments << segment
			}
		}
		clean := '/' + segments.join('/')
		matched_path = if path.ends_with('/') && clean != '/' { clean + '/' } else { clean }
	}
	for route in site.routes {
		if route.patterns.len == 0 { return route }
		for pattern in route.patterns {
			if pattern == '*' || pattern == matched_path || (pattern.ends_with('*') && matched_path.starts_with(pattern[..pattern.len - 1])) {
				return route
			}
		}
	}
	return none
}

fn rewrite_uri(uri string, target string) string {
	if target == '' { return uri }
	if target.contains('{uri}') { return target.replace('{uri}', uri) }
	if target.contains('?') || !uri.contains('?') { return target }
	return target + '?' + uri.all_after('?')
}
