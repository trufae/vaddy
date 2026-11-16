module main

import os

fn test_port_only_http_sites() ! {
	for address in [':1234', 'http://:1234', 'HTTP://:1234', ':80', ':65535'] {
		cfg := parse_config('${address} {\n respond "It works!"\n}')!
		assert cfg.http_port == address.all_after_last(':').int()
		assert cfg.sites[0].plain
		assert cfg.sites[0].hosts == ['*']
		assert cfg.domains().len == 0
		if _ := cfg.tls_site() { assert false }
		assert cfg.site_index('anything.example', false) == 0
		assert cfg.site_index('127.0.0.1', false) == 0
		assert cfg.site_index('anything.example', true) == -1
	}
	cfg := load_config(':1234 {\n respond ok\n}', Options{http_port: '8080'})!
	assert cfg.http_port == 8080
	remapped := parse_config('{\n https_port 8443\n}\n:443 {\n respond ok\n}')!
	assert remapped.http_port == 443 && remapped.sites[0].plain
}

fn test_port_only_named_site_precedence_and_protocols() ! {
	fallback := ':1234 {\n respond fallback\n}'
	named := 'http://example.org {\n respond named\n}'
	for sites in ['${fallback}\n${named}', '${named}\n${fallback}'] {
		cfg := parse_config('{\n http_port 1234\n}\n${sites}')!
		assert cfg.sites[cfg.site_index('example.org', false)].routes[0].respond? == 'named'
		assert cfg.sites[cfg.site_index('other.example', false)].routes[0].respond? == 'fallback'
	}
	cfg := parse_config('{\n http_port 1234\n}\n${fallback}\nexample.org {\n tls internal\n respond secure\n}')!
	assert cfg.domains() == ['example.org']
	assert cfg.site_index('example.org', false) == 1
	assert cfg.site_index('example.org', true) == 1
	assert cfg.site_index('other.example', false) == 0
	assert cfg.site_index('other.example', true) == -1

	aliases := parse_config(':80, http://example.org {\n respond ok\n}')!
	assert aliases.site_index('other.example', false) == 0
}

fn test_port_only_https_sites() ! {
	for address in [':443', 'https://:8443', ':8443'] {
		cfg := parse_config('${address} {\n tls cert.pem key.pem\n respond secure\n}')!
		assert cfg.https_port == address.all_after_last(':').int()
		assert !cfg.sites[0].plain
		assert cfg.domains().len == 0
		assert cfg.site_index('anything.example', true) == 0
		assert cfg.site_index('anything.example', false) == -1
	}
	cfg := parse_config('{\n https_port 8443\n}\n:8443 {\n tls cert.pem key.pem\n respond secure\n}')!
	assert !cfg.sites[0].plain
	shared := parse_config(':443 {\n tls internal\n respond fallback\n}\nexample.org {\n tls internal\n respond named\n}')!
	assert shared.domains() == ['example.org']
	assert shared.site_index('example.org', true) == 1
	assert shared.site_index('other.example', true) == 0
}

fn test_invalid_or_conflicting_port_only_sites() {
	for address in [':', ':0', ':65536', ':-1', ':+80', ':abc', ':1234/path', ':1234:5678',
		':443', 'https://:8443', 'http://:443', 'https://:80', 'https://http://:1234'] {
		if _ := parse_config('${address} {\n respond ok\n}') { assert false, address }
	}
	for input in [
		':1234 {\n respond a\n}\n:1235 {\n respond b\n}',
		':1234 {\n respond a\n}\nhttp://:1234 {\n respond b\n}',
		':1234, :1235 {\n respond a\n}',
		':1234 {\n respond a\n}\nhttp://example.org {\n respond b\n}',
		':1234 {\n respond a\n}\nexample.org {\n respond b\n}',
		':1234 {\n tls internal\n respond a\n}',
		'http://:1234 {\n tls cert.pem key.pem\n respond a\n}',
		':80 {\n tls cert.pem key.pem\n respond a\n}',
		':8443 {\n tls cert.pem key.pem\n respond a\n}\nexample.org {\n tls cert.pem key.pem\n respond b\n}',
	] {
		if _ := parse_config(input) { assert false, input }
	}
}

fn test_supplied_caddyfile() ! {
	cfg := parse_config(os.read_file(os.join_path(@VMODROOT, 'Caddyfile'))!)!
	assert cfg.http_port == 80 && cfg.https_port == 443
	assert cfg.domains() == ['example.org']
	site := cfg.sites[0]
	assert site.response_headers.map(it.lower) == ['cross-origin-embedder-policy', 'cross-origin-opener-policy']
	cases := {
		'/assets/app.js?x=1':    '/static/assets/app.js?x=1'
		'/app.js':               '/static/app.js'
		'/styles.css?v=2':       '/static/styles.css?v=2'
		'/manifest.webmanifest': '/static/manifest.webmanifest'
		'/favicon.ico?old=1':    '/static/assets/favicon.ico?old=1'
		'/favicon.svg':          '/static/assets/favicon.svg'
		'/api/stream?q=a%20b':   '/api/stream?q=a%20b'
		'/assets':               '/assets'
		'/APP.JS':               '/static/APP.JS'
		'/%61pp.js?q=1':         '/static/%61pp.js?q=1'
	}
	for uri, expected in cases {
		route := site.route_for(uri) or { panic(uri) }
		assert route.upstream == 'localhost:8001'
		assert rewrite_uri(uri, route.rewrite) == expected
	}
}

fn test_config_rejects_unsupported_or_invalid_features() {
	for input in [
		'example.org {\n encode gzip\n}',
		'example.org {\n reverse_proxy localhost:8001 {\n transport http\n }\n}',
		'example.org {\n handle @missing {\n reverse_proxy localhost:8001\n }\n}',
		'example.org {\n reverse_proxy localhost:8001\n',
		'{\n admin localhost:2019\n}\nexample.org {\n reverse_proxy localhost:8001\n}',
		'example.org {\n header -Content-Length\n reverse_proxy localhost:8001\n}',
		'example.org {\n handle /a*b {\n reverse_proxy localhost:8001\n }\n}',
	] {
		if _ := parse_config(input) {
			assert false, input
		}
	}
}

fn test_matcher_specificity_and_query_preservation() ! {
	cfg := parse_config('http://localhost {\n handle {\n reverse_proxy localhost:8001\n }\n handle /api/* {\n rewrite * /fallback\n reverse_proxy localhost:8001\n }\n handle /api/exact {\n rewrite * /exact\n reverse_proxy localhost:8001\n }\n}')!
	site := cfg.sites[0]
	assert site.route_for('/api/exact?q=1')?.rewrite == '/exact'
	assert site.route_for('/api/a')?.rewrite == '/fallback'
	assert site.route_for('/other')?.rewrite == ''
	assert rewrite_uri('/old?q=1', '/new') == '/new?q=1'
	assert rewrite_uri('/old?q=1', '/new?q=2') == '/new?q=2'
}

fn test_path_normalization_and_case_insensitive_matchers() ! {
	cfg := parse_config('http://localhost {\n handle /Assets/* {\n rewrite * /matched\n reverse_proxy localhost:8001\n }\n handle /Exact {\n rewrite * /exact\n reverse_proxy localhost:8001\n }\n handle {\n reverse_proxy localhost:8001\n }\n}')!
	site := cfg.sites[0]
	for uri in ['/assets/a.js', '/ASSETS/a.js', '/assets/', '/assets//a.js', '/assets/./a.js',
		'/a/../assets/a.js', '/%61ssets/a.js', '/assets%2Fa.js', '/assets/a/../b.js?x=1'] {
		assert site.route_for(uri)?.rewrite == '/matched', uri
	}
	for uri in ['/exact', '/EXACT', '/./exact', '//exact', '/a/../exact'] {
		assert site.route_for(uri)?.rewrite == '/exact', uri
	}
	for uri in ['/assets', '/assets/../other', '/exact/', '/.hidden', '/'] {
		assert site.route_for(uri)?.rewrite == '', uri
	}
}

fn test_https_upstreams_and_transport_validation() ! {
	assert upstream_address('http://localhost')! == 'localhost:80'
	assert upstream_address('https://localhost')! == 'https://localhost:443'
	assert upstream_address('https://[::1]:8443')! == 'https://[::1]:8443'
	cfg := parse_config('http://localhost {\n handle {\n reverse_proxy https://127.0.0.1:8443 {\n transport http {\n tls_server_name localhost\n tls_trust_pool file /tmp/ca.pem\n }\n }\n }\n}')!
	route := cfg.sites[0].routes[0]
	assert route.tls_server_name == 'localhost'
	assert route.tls_ca == '/tmp/ca.pem'
	for address in ['ftp://localhost', 'https://a/b', 'https://user@host', 'https://a?b=c', 'https://a:0'] {
		if _ := upstream_address(address) { assert false, address }
	}
	for option in ['tls_insecure_skip_verify', 'tls_server_name wrong/name', 'tls_trust_pool unknown file'] {
		if _ := parse_config('http://localhost {\n reverse_proxy https://localhost {\n transport http {\n ${option}\n }\n }\n}') { assert false, option }
	}
}

fn test_redirect_only_sites_and_invalid_redirects() ! {
	cfg := parse_config('http://localhost {\n redir https://example.org{uri}\n}')!
	assert cfg.sites[0].route_for('/any')?.redirect_code == 302
	for directive in ['redir * /new 200', 'redir * /new 9999999999999999999999999999999999999999999999999999999999999999999999999999', 'redir "bad\rvalue"'] {
		if _ := parse_config('http://localhost {\n ${directive}\n}') { assert false, directive }
	}
	if _ := parse_config('http://localhost {\n handle {\n redir /new\n reverse_proxy localhost:8001\n }\n}') { assert false }
}

fn test_quoted_windows_paths_preserve_backslashes() ! {
	tokens := tokenize(r'header X-Path "C:\server\data"')!
	assert tokens[2].text == r'C:\server\data'
	escaped := tokenize(r'header X-Message "say \"hello\""')!
	assert escaped[2].text == 'say "hello"'
}
