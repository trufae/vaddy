module main

import os

fn test_supplied_caddyfile() ! {
	cfg := parse_config(os.read_file(os.join_path(@VMODROOT, 'Caddyfile'))!)!
	assert cfg.http_port == 80 && cfg.https_port == 443
	assert cfg.domains() == ['example.org']
	site := cfg.sites[0]
	assert site.remove_headers == ['cross-origin-embedder-policy', 'cross-origin-opener-policy']
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
