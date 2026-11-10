module main

fn parse_message(raw string, request bool, head bool) !Message {
	return parse_message_reuse(raw, request, head, []Field{})
}

fn request_header(m Message, uri string, ip string, tls bool) string {
	mut b := Buffer{}
	b.request_header(m, uri, ip, tls)
	return b.bytes().bytestr()
}

fn response_header(m Message, remove []string, close bool) string {
	mut b := Buffer{}
	b.response_header(m, remove, close)
	return b.bytes().bytestr()
}

fn test_reused_header_storage_does_not_retain_previous_message_state() ! {
	first := parse_message('POST /first HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nConnection: close\r\nX-Old: remove\r\n\r\n', true, false)!
	second := parse_message_reuse('GET /second HTTP/1.1\r\nHost: localhost\r\n\r\n', true, false, first.fields)!
	assert second.fields.len == 1
	assert second.frame.done && !second.close
	assert second.connection.len == 0
	encoded := request_header(second, second.uri, '127.0.0.1', true)
	assert !encoded.contains('X-Old') && !encoded.contains('Content-Length')
	assert encoded.starts_with('GET /second HTTP/1.1\r\n')
}

fn test_header_count_and_token_boundaries() ! {
	allowed := 'GET / HTTP/1.1\r\nHost: localhost\r\n' + 'X-Test: v\r\n'.repeat(127) + '\r\n'
	assert parse_message(allowed, true, false)!.fields.len == 128
	too_many := 'GET / HTTP/1.1\r\nHost: localhost\r\n' + 'X-Test: v\r\n'.repeat(128) + '\r\n'
	if _ := parse_message(too_many, true, false) {
		assert false
	}
	assert is_token("AZaz09!#$%&'*+-.^_`|~")
	for bad in ['', 'bad name', 'name:', 'name\t', 'name\r', 'name\n', 'name\x00', 'name\x7f',
		'name/'] {
		assert !is_token(bad), bad
	}
	for host in ['-name', 'name-', '.name', 'name.', 'a..b', 'a/b', 'a@b', 'a:b'] {
		assert !valid_host(host), host
	}
	assert valid_host('a-b.example.org')
}

fn test_http_rejects_ambiguous_messages() {
	for raw in [
		'GET / HTTP/1.1\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: gzip, chunked\r\n\r\n',
		'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 9223372036854775808\r\n\r\n',
		'GET / HTTP/1.1\r\nHost : a\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: a\r\n folded: no\r\n\r\n',
		'GET / HTTP/1.1\r\nHost: a\r\nConnection: content-length\r\n\r\n',
		'GET /bad%xx HTTP/1.1\r\nHost: a\r\n\r\n',
		'GET http://example.org/ HTTP/1.1\r\nHost: a\r\n\r\n',
	] {
		if _ := parse_message(raw, true, false) {
			assert false, raw
		}
	}
}

fn test_chunked_framing_all_fragment_boundaries() ! {
	body := '4;name=value\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Test: yes\r\n\r\n'
	for split in 0 .. body.len + 1 {
		mut frame := Framing{ kind: .chunked }
		assert frame.consume(body[..split].bytes())! == split
		assert frame.consume((body[split..] + 'GET /next HTTP/1.1\r\n').bytes())! == body.len - split
		assert frame.done
	}
	mut frame := Framing{ kind: .chunked }
	for c in body.bytes() {
		assert frame.consume([c])! == 1
	}
	assert frame.done
	for invalid in ['z\r\n', '1\r\nxXX', '1\nx\n', '0\r\nContent-Length: 3\r\n\r\n', '-1\r\n'] {
		mut bad := Framing{ kind: .chunked }
		if _ := bad.consume(invalid.bytes()) {
			assert false, invalid
		}
	}
}

fn test_proxy_headers_and_no_body_statuses() ! {
	m := parse_message('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: x-hop\r\nX-Hop: remove\r\nX-Forwarded-For: spoof\r\nX-Forwarded-Proto: spoof\r\nX-Forwarded-Host: spoof\r\n\r\n', true, false)!
	header := request_header(m, '/static/', '127.0.0.1', true)
	assert !header.contains('spoof') && !header.contains('X-Hop')
	assert header.contains('X-Forwarded-For: 127.0.0.1\r\n')
	assert header.contains('X-Forwarded-Proto: https\r\n')
	assert header.contains('Host: localhost\r\n')
	for status in ['204 No Content', '304 Not Modified', '103 Early Hints'] {
		resp := parse_message('HTTP/1.1 ${status}\r\n\r\n', false, false)!
		assert resp.frame.done
	}
	head := parse_message('HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n', false, true)!
	assert head.frame.done
	assert response_header(head, [], false).contains('Content-Length: 1234')
	mut frame := Framing{ kind: .length, remaining: 3 }
	assert frame.consume('abcNEXT'.bytes())! == 3
	assert frame.done
}
