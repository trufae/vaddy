module main

import net.urllib
import src.caddyfile { Directive }
import src.log

struct Route {
mut:
	files FileConfig
	root string
	encode EncodeConfig
	log_rules []LogRule
	patterns []string
	matcher  string
	redirect string
	redirect_code int = 302
	redirect_status string
	redirect_html bool
	redirect_first bool
	respond  ?string
	rewrite  string
	upstream string
	tls_server_name string
	tls_ca string
	request_headers []HeaderEdit
	response_headers []HeaderEdit
}

struct Site {
mut:
	root string = '.'
	encode EncodeConfig
	logs []&log.Config
	log_rules []LogRule
	hosts          []string
	plain          bool
	port           int
	response_headers []HeaderEdit
	request_headers []HeaderEdit
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
	tls := s.starts_with('https://')
	value := s.trim_string_left('https://').trim_string_left('http://')
	u := urllib.parse('http://${value}')!
	if u.hostname() == '' || u.path !in ['', '/'] || u.raw_query != '' || u.fragment != '' || value.contains('@') || value.contains('://') || invalid_controls(value, false) {
		return error('reverse_proxy requires one HTTP or HTTPS host:port upstream')
	}
	port := if u.port() == '' { if tls { '443' } else { '80' } } else { u.port() }
	port_value(port)!
	host := if u.hostname().contains(':') { '[${u.hostname()}]' } else { u.hostname() }
	return '${if tls { 'https://' } else { '' }}${host}:${port}'
}

fn (r Route) backend_key() string {
	if !r.upstream.starts_with('https://') { return r.upstream }
	return '${r.upstream}\n${r.tls_server_name}\n${r.tls_ca}'
}

fn parse_proxy(d Directive, mut route Route) ! {
	if d.args.len != 2 || route.upstream != '' { return error('expected reverse_proxy host:port') }
	route.upstream = upstream_address(d.args[1])!
	mut transport_seen := false
	for child in d.children {
		if child.args.len > 0 && child.args[0] in ['header_up', 'header_down'] {
			base := parse_header_edit(child.args[1..], child.children.len > 0, true)!
			edit := HeaderEdit{...base, proxy: true, group: 'proxy'}
			if child.args[0] == 'header_up' { route.request_headers << edit } else { route.response_headers << edit }
			continue
		}
		if child.args != ['transport', 'http'] || transport_seen || child.children.len == 0 {
			return error('unsupported reverse_proxy option')
		}
		transport_seen = true
		for opt in child.children {
			if opt.children.len > 0 { return error('unsupported transport block') }
			if opt.args.len == 2 && opt.args[0] == 'tls_server_name' && route.tls_server_name == '' && valid_host(opt.args[1]) {
				route.tls_server_name = opt.args[1]
			} else if opt.args.len == 3 && opt.args[..2] == ['tls_trust_pool', 'file'] && route.tls_ca == '' {
				route.tls_ca = opt.args[2]
			} else {
				return error('supported transport options: tls_server_name and tls_trust_pool file')
			}
		}
	}
	if transport_seen && !route.upstream.starts_with('https://') {
		return error('TLS transport options require an https:// upstream')
	}
}

fn parse_respond(d Directive) !Route {
	if d.children.len > 0 || d.args.len !in [2, 3] {
		return error('line ${d.line}: expected respond [matcher] body')
	}
	validate_respond_body(d.args.last()) or { return error('line ${d.line}: ${err}') }
	mut route := Route{respond: d.args.last()}
	if d.args.len == 3 {
		matcher := d.args[1]
		if matcher.starts_with('@') { route.matcher = matcher }
		else if matcher.starts_with('/') { route.patterns = [matcher] }
		else if matcher != '*' { return error('line ${d.line}: invalid respond matcher') }
	}
	return route
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
		if child.args.len == 0 || (child.children.len > 0 && child.args[0] !in ['reverse_proxy', 'header', 'request_header', 'encode', 'file_server']) {
			return error('line ${child.line}: unsupported nested directive')
		}
		match child.args[0] {
			'root' { route.root = parse_root(child)! }
			'file_server' {
				if route.files.enabled { return error('duplicate file_server') }
				files := parse_file_server(child)!
				if files.patterns.len > 0 || files.matcher != '' { return error('put file_server matcher on handle') }
				route.files = files.files
				if files.root != '' { route.root = files.root }
			}
			'encode' {
				if route.encode.enabled { return error('duplicate encode directive') }
				route.encode = parse_encode(child)!
			}
			'log_skip', 'skip_log', 'log_level', 'log_name', 'log_append' { route.log_rules << parse_log_rule(child)! }
			'header' { route.response_headers << parse_headers(child, false)! }
			'request_header' { route.request_headers << parse_headers(child, true)! }
			'redir' {
				if route.redirect != '' { return error('handle has multiple redirects') }
				redirect := parse_redirect(child)!
				if redirect.patterns.len > 0 || redirect.matcher != '' { return error('put redirect matcher on handle') }
				route.redirect = redirect.redirect
				route.redirect_code = redirect.redirect_code
				route.redirect_status = redirect.redirect_status
				route.redirect_html = redirect.redirect_html
			}
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
				parse_proxy(child, mut route)!
			}
			'respond' {
				if route.respond != none { return error('duplicate respond') }
				response := parse_respond(child)!
				if response.matcher != '' || response.patterns.len > 0 { return error('put respond matcher on handle') }
				route.respond = response.respond
			}
			else {
				return error('line ${child.line}: unsupported handle directive ${child.args[0]}')
			}
		}
	}
	if int(route.upstream != '') + int(route.redirect != '') + int(route.files.enabled) + int(route.respond != none) != 1 { return error('handle needs exactly one reverse_proxy, redir, file_server or respond') }
	if route.redirect != '' && route.rewrite != '' { return error('rewrite and redir cannot share a handle') }
	return route
}

fn route_before(a Route, b Route) bool {
	if a.redirect_first != b.redirect_first { return a.redirect_first }
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
	nodes := caddyfile.parse(input)!
	mut cfg := Config{}
	mut hosts := map[string]bool{}
	mut log_count := 0
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
			address := addr.trim_right(',').to_lower()
			mut host := address
			if host.starts_with('http://') { host = host['http://'.len..] }
			else if host.starts_with('https://') { host = host['https://'.len..] }
			mut plain := address.starts_with('http://')
			mut port := if plain { cfg.http_port } else { cfg.https_port }
			if host.starts_with(':') {
				port = port_value(host[1..])!
				explicit_https := address.starts_with('https://')
				has_tls := d.children.any(it.args.len > 0 && it.args[0] == 'tls')
				if (plain && port == cfg.https_port) || (explicit_https && port == cfg.http_port) {
					return error('line ${d.line}: site scheme conflicts with configured HTTP/HTTPS port: ${addr}')
				}
				plain = !explicit_https && port != cfg.https_port && (plain || port == cfg.http_port || !has_tls)
				if plain && has_tls { return error('line ${d.line}: HTTP site cannot configure TLS: ${addr}') }
				host = '*'
			} else if !valid_host(host) {
				return error('line ${d.line}: expected DNS hostname or :port (use global http_port/https_port for hostname ports): ${addr}')
			}
			if site.hosts.len > 0 && plain != site.plain {
				return error('cannot mix HTTP and HTTPS addresses in a site')
			}
			if site.hosts.len > 0 && port != site.port { return error('site addresses must share one listener port') }
			key := '${if plain { 'http' } else { 'https' }}://${host}:${port}'
			if key in hosts { return error('duplicate site: ${addr}') }
			hosts[key] = true
			site.hosts << host
			site.plain = plain
			site.port = port
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
				'root' { site.root = parse_root(child)! }
				'file_server' { site.routes << parse_file_server(child)! }
				'respond' { site.routes << parse_respond(child)! }
				'encode' {
					if site.encode.enabled { return error('duplicate encode directive') }
					site.encode = parse_encode(child)!
				}
				'log' {
					log_config := log.parse(child, 'log${log_count}')!
					site.logs << log_config
					if child.args.len == 1 && log_config.name != '' { log_count++ }
				}
				'log_skip', 'skip_log', 'log_level', 'log_name', 'log_append' { site.log_rules << parse_log_rule(child)! }
				'header' { site.response_headers << parse_headers(child, false)! }
				'request_header' { site.request_headers << parse_headers(child, true)! }
				'handle' { site.routes << parse_route(child)! }
				'redir' {
					mut route := parse_redirect(child)!
					route.redirect_first = true
					site.routes << route
				}
				'reverse_proxy' {
					mut route := Route{}
					parse_proxy(child, mut route)!
					site.routes << route
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
		if site.routes.len == 0 { return error('site needs reverse_proxy, file_server, handle, redir or respond') }
		resolve_log_rules(mut site.log_rules, site.matchers)!
		resolve_encode(mut site.encode, site.matchers)!
		resolve_header_matchers(mut site.response_headers, site.matchers)!
		resolve_header_matchers(mut site.request_headers, site.matchers)!
		mut fallbacks := 0
		for mut route in site.routes {
			resolve_encode(mut route.encode, site.matchers)!
			resolve_log_rules(mut route.log_rules, site.matchers)!
			resolve_header_matchers(mut route.response_headers, site.matchers)!
			resolve_header_matchers(mut route.request_headers, site.matchers)!
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
			if route.patterns.len == 0 && !route.redirect_first { fallbacks++ }
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
	mut log_names := map[string]bool{}
	for site in cfg.sites {
		for config in site.logs {
			if config.name != '' && config.name in log_names { return error('duplicate log name ${config.name}') }
			log_names[config.name] = true
		}
	}
	for site in cfg.sites {
		mut rules := site.log_rules.clone()
		for route in site.routes { rules << route.log_rules }
		for rule in rules {
			if rule.kind == 'log_name' { for name in rule.args { if name !in log_names { return error('undefined log name ${name}') } } }
		}
	}
	if cfg.sites.len == 0 { return error('no sites configured') }
	mut http_port := 0
	mut https_port := 0
	mut policy := ''
	for site in cfg.sites {
		if site.plain {
			if http_port != 0 && http_port != site.port { return error('only one HTTP listener port is supported') }
			http_port = site.port
			continue
		}
		if https_port != 0 && https_port != site.port { return error('only one HTTPS listener port is supported') }
		https_port = site.port
		p := '${site.tls_mode}|${site.cert}|${site.key}'
		if policy != '' && policy != p {
			return error('HTTPS sites must share one TLS policy; certificates cover all configured names')
		}
		policy = p
	}
	if https_port != 0 {
		if http_port != 0 && http_port != cfg.http_port {
			return error('HTTP sites must use the global http_port when HTTPS is enabled')
		}
		cfg.https_port = https_port
		if cfg.domains().len == 0 && cfg.sites.any(!it.plain && it.tls_mode != 'manual') {
			return error('hostname-free HTTPS requires tls cert.pem key.pem')
		}
	}
	if http_port != 0 { cfg.http_port = http_port }
	if cfg.http_port == cfg.https_port { return error('HTTP and HTTPS ports must differ') }
	return cfg
}

fn (cfg Config) tls_site() ?Site {
	for site in cfg.sites { if !site.plain { return site } }
	return none
}

fn (cfg Config) domains() []string {
	mut result := []string{}
	for site in cfg.sites { if !site.plain { result << site.hosts.filter(it != '*') } }
	return result
}

fn (cfg Config) site_index(name string, tls bool) int {
	mut fallback := -1
	mut redirect := -1
	for i, site in cfg.sites {
		if site.plain == tls {
			if !tls && name in site.hosts { redirect = i }
			continue
		}
		if name in site.hosts { return i }
		if '*' in site.hosts { fallback = i }
	}
	// Named HTTPS redirects precede the HTTP catch-all, just like named sites.
	return if redirect >= 0 { redirect } else { fallback }
}

fn normalized_path(uri string) ?string {
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
	return matched_path
}

fn (site Site) route_for(uri string) ?Route {
	matched_path := normalized_path(uri) or { return none }
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

struct LogRule {
	kind string
	args []string
mut:
	match HeaderEdit
}

fn parse_log_rule(d Directive) !LogRule {
	if d.children.len > 0 { return error('log request directives do not accept blocks') }
	mut args := d.args[1..].clone()
	matcher := take_header_matcher(mut args)
	kind := d.args[0]
	match kind {
		'log_skip', 'skip_log' { if args.len != 0 { return error('log_skip accepts only a matcher') } }
		'log_level' { if args.len != 1 { return error('expected log_level [matcher] LEVEL') }; log.level(args[0])! }
		'log_append' { if args.len != 2 || args[0].trim_string_left('<') == '' { return error('expected log_append [matcher] KEY VALUE') } }
		'log_name' { if args.len == 0 { return error('expected log_name [matcher] NAME...') } }
		else { return error('unknown log request directive') }
	}
	return LogRule{kind, args, matcher}
}

fn resolve_log_rules(mut rules []LogRule, matchers map[string][]string) ! {
	for mut rule in rules {
		mut headers := [rule.match]
		resolve_header_matchers(mut headers, matchers)!
		rule.match = headers[0]
	}
}

fn (cfg &Config) log_configs() []&log.Config {
	mut configs := []&log.Config{}
	for site in &cfg.sites { configs << site.logs }
	return configs
}
