module main

fn test_encoding_negotiation_and_configuration() {
	formats := ['zstd', 'gzip']
	assert accepted_encoding([Field{'', 'accept-encoding', 'gzip, zstd'}], formats) == 'zstd'
	assert accepted_encoding([Field{'', 'accept-encoding', 'gzip;q=0.8, zstd;q=0.2'}], formats) == 'gzip'
	assert accepted_encoding([Field{'', 'accept-encoding', 'gzip;q=0, identity, *'}], formats) == ''
	cfg := parse_config('http://localhost {\n encode {\n gzip 6\n minimum_length 128\n }\n reverse_proxy localhost:9000\n}') or { panic(err) }
	assert cfg.sites[0].encode.gzip_level == 6
	assert cfg.sites[0].encode.minimum == 128
	for directive in ['encode brotli', 'encode gzip gzip', 'encode {\n minimum_length 999999\n}', 'encode {\n gzip 99\n}'] {
		if _ := parse_config('http://localhost {\n ${directive}\n reverse_proxy localhost:9000\n}') { assert false }
	}
}

fn test_decoded_chunks_at_every_input_boundary() {
	raw := '4\r\nWiki\r\n5\r\npedia\r\n0\r\nX-Trailer: value\r\n\r\n'.bytes()
	for split in 1 .. raw.len {
		mut frame := Framing{kind: .chunked}
		mut output := Buffer{}
		assert frame.consume_decoded(raw[..split], mut output) or { panic(err) } == split
		assert frame.consume_decoded(raw[split..], mut output) or { panic(err) } == raw.len - split
		assert output.bytes().bytestr() == 'Wikipedia'
		assert frame.done
	}
}
