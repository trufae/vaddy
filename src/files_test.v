module main

import os

fn test_file_paths_ranges_and_conditions() {
	assert file_path('/public', '/a/../../hello.txt') or { panic(err) } == os.abs_path('/public/hello.txt')
	assert file_path('/public', '/%2e%2e/hello.txt') or { panic(err) } == os.abs_path('/public/hello.txt')
	for path in ['/a%00b', '/a%5cb', '/C:%5csecret', '/%ff%00'] {
		if _ := file_path('/public', path) { assert false, path }
	}
	assert parse_file_ranges('bytes=0-3,8-20', 10) or { panic(err) } == [FileRange{0, 4}, FileRange{8, 2}]
	assert parse_file_ranges('bytes=-3', 10) or { panic(err) } == [FileRange{7, 3}]
	assert parse_file_ranges('bytes=0-9,0-9', 10) or { panic(err) } == []FileRange{}
	for value in ['bytes=20-30', 'bytes=-0', 'bytes=4-2', 'bytes=9223372036854775808-', 'items=0-1'] {
		if _ := parse_file_ranges(value, 10) { assert false, value }
	}
	assert file_condition([Field{'', 'if-none-match', 'W/"tag"'}], '"tag"', 100) == 304
	assert file_condition([Field{'', 'if-match', 'W/"tag"'}], '"tag"', 100) == 412
	assert file_condition([Field{'', 'if-none-match', '"wrong"'}, Field{'', 'if-modified-since', 'Wed, 11 Nov 2026 00:00:00 GMT'}], '"tag"', 100) == 200
}

fn test_static_configuration() {
	config := parse_config('http://localhost {\n root * ./public\n file_server {\n browse\n index welcome.html index.txt\n hide .git secret*\n }\n}') or { panic(err) }
	assert config.sites[0].root == './public'
	assert config.sites[0].routes[0].files.indexes == ['welcome.html', 'index.txt']
	for directive in ['file_server {\n index ../private\n}', 'root /path/* /public\nfile_server', 'handle {\nfile_server\nreverse_proxy localhost:9000\n}'] {
		if _ := parse_config('http://localhost {\n${directive}\n}') { assert false, directive }
	}
}
